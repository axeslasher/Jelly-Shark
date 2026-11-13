import DesignSystem
import Foundation
import JellyfinKit
import Observation

/// Connection state for the server connection flow
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
}

/// View model for managing Jellyfin server connection
@Observable
@MainActor
public final class ServerConnectionViewModel {
    // MARK: - Input State

    /// Server URL input (e.g., "https://demo.jellyfin.org/stable")
    public var serverURL: String = "https://demo.jellyfin.org/stable"

    /// Username input
    public var username: String = "demo"

    /// Password input
    public var password: String = ""

    // MARK: - Connection State

    /// Current connection state
    public private(set) var state: ConnectionState = .disconnected

    /// Whether the launch-time session restore has run to completion (found
    /// no saved session, failed, or connected). Until this flips, a
    /// `.disconnected` state is provisional — screens should show a loading
    /// treatment rather than the "not connected" placeholder.
    public private(set) var hasAttemptedRestore = false

    /// Whether a cache-restored session is still being validated against the
    /// server in the background. `state` is already `.connected` while this
    /// is true — the session renders from cache and either stands (validated
    /// or offline) or tears down (the token was revoked).
    public private(set) var isValidating = false

    /// Error message if connection/auth failed
    public private(set) var errorMessage: String?

    // MARK: - Results

    /// The authenticated user
    public private(set) var connectedUser: User?

    /// Libraries fetched from the server
    public private(set) var libraries: [Library] = []

    /// The server's Live TV view, when it has one. Kept out of `libraries`,
    /// which holds only what opens as a poster grid; Live TV opens the guide.
    public private(set) var liveTVLibrary: Library?

    /// Item counts per library ID for the Server page, fetched after the
    /// libraries publish — one `TotalRecordCount` query each, because the
    /// `ChildCount` the Views endpoint reports is noise on Jellyfin 10.11.
    /// A library with no entry (fetch failed, or still in flight) shows no
    /// count line rather than a wrong one.
    public private(set) var libraryCounts: [String: Int] = [:]

    // MARK: - Profiles

    /// Every saved profile, most recently used first
    public private(set) var profiles: [SavedSession] = []

    /// The profile the app restores on launch; nil when none is active
    public private(set) var activeProfileID: ProfileID?

    /// Whether an Add Profile sign-in is in flight. The current session stays
    /// connected while it runs, so this is separate from `state`.
    public private(set) var isAddingProfile = false

    /// The active profile, when it is saved
    public var activeProfile: SavedSession? {
        profiles.first { $0.id == activeProfileID }
    }

    /// Saved profiles other than the active one: the ones a viewer can
    /// switch to
    public var otherProfiles: [SavedSession] {
        profiles.filter { $0.id != activeProfileID }
    }

    // MARK: - Private

    /// The Jellyfin client instance
    private var client: (any JellyfinClientProtocol)?

    /// The metadata cache; nil (previews, tests without one) disables both
    /// instant connect and write-through, restoring the blocking flow
    private let cache: MediaCacheStore?

    /// The in-flight background validation of an instantly-restored session
    private var validationTask: Task<Void, Never>?

    /// The in-flight per-library count fetch
    private var countsTask: Task<Void, Never>?

    /// Shared session to publish the client into after connecting
    private weak var session: AppSession?

    /// Persisted session storage (Keychain-backed in production)
    private let sessionStore: any SessionStoring

    /// Factory for building clients (injectable for tests); the saved session
    /// is non-nil when restoring rather than authenticating fresh
    private let makeClient: @MainActor (
        JellyfinClientConfiguration, _ restoredSession: SavedSession?,
    ) -> any JellyfinClientProtocol

    /// Encoded artwork bytes and decoded images, emptied on sign-out;
    /// injectable so a test can observe the purge
    private let urlCache: URLCache
    private let artworkLoader: ArtworkLoader

    // MARK: - Initialization

    public init(
        sessionStore: any SessionStoring = SessionStore(),
        makeClient: @escaping @MainActor (
            JellyfinClientConfiguration, SavedSession?,
        ) -> any JellyfinClientProtocol = { configuration, restored in
            JellyfinClient(
                configuration: configuration,
                accessToken: restored?.accessToken,
                userID: restored?.userID,
            )
        },
        cache: MediaCacheStore? = nil,
        urlCache: URLCache = .shared,
        artworkLoader: ArtworkLoader = .shared,
    ) {
        self.sessionStore = sessionStore
        self.makeClient = makeClient
        self.cache = cache
        self.urlCache = urlCache
        self.artworkLoader = artworkLoader
        reloadProfiles()
    }

    /// Attach the shared session so the connected client can be published app-wide
    public func attach(session: AppSession) {
        self.session = session
    }

    // MARK: - Actions

    /// Connect to the server and authenticate
    public func connect() async {
        // Ignore re-entrant taps while a connection attempt is in flight
        guard state != .connecting, state != .authenticating else { return }

        // Clear previous error
        errorMessage = nil

        guard let url = validatedServerURL() else { return }

        // Start connecting
        state = .connecting

        // Create client
        let newClient = wrapped(makeClient(makeConfiguration(serverURL: url), nil))
        self.client = newClient

        // Authenticate
        state = .authenticating

        do {
            let (user, serverName) = try await signIn(with: newClient)
            try await completeConnection(client: newClient, user: user)
            persistSession(for: newClient, serverURL: url, user: user, serverName: serverName)
            password = ""
        } catch {
            errorMessage = error.localizedDescription
            state = .disconnected
            client = nil
        }
    }

    /// Sign in to another server or user while the current session stays
    /// up, then make the new profile the active one. The current profile is
    /// kept, token and cache included, so the viewer can switch back.
    ///
    /// - Returns: Whether the new profile is now connected. On failure the
    ///   current session is untouched and `errorMessage` says why.
    @discardableResult
    public func addProfile() async -> Bool {
        guard !isAddingProfile, state == .connected else { return false }
        errorMessage = nil
        guard let url = validatedServerURL() else { return false }

        isAddingProfile = true
        defer { isAddingProfile = false }

        let newClient = wrapped(makeClient(makeConfiguration(serverURL: url), nil))
        let user: User
        let serverName: String
        do {
            (user, serverName) = try await signIn(with: newClient)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        // Proved before the current session is retired, so a failure here
        // leaves the viewer exactly where they were
        let libraries: [Library]
        do {
            libraries = try await newClient.getLibraries()
        } catch {
            // The server issued a token nothing will save; end it there
            await newClient.signOut()
            errorMessage = error.localizedDescription
            return false
        }

        endSessionLocally()
        client = newClient
        publishConnection(client: newClient, user: user, libraries: libraries)
        persistSession(for: newClient, serverURL: url, user: user, serverName: serverName)
        password = ""
        return true
    }

    /// Reset the form for Add Profile. The server URL is kept, since a second
    /// user on the same server is the common case; the credentials are not.
    public func prepareAddProfile() {
        username = ""
        password = ""
        errorMessage = nil
    }

    /// Make a saved profile the active one and restore its session. The
    /// profile being left keeps its token and its cache: it is switched
    /// away from, not signed out.
    public func switchToProfile(_ id: ProfileID) async {
        guard profiles.contains(where: { $0.id == id }) else { return }
        guard id != activeProfileID || state == .disconnected else { return }
        guard state != .connecting, state != .authenticating, !isAddingProfile else { return }

        endSessionLocally()
        do {
            try sessionStore.activate(id)
        } catch {
            errorMessage = error.localizedDescription
            reloadProfiles()
            return
        }
        reloadProfiles()
        await restoreSession()
    }

    /// Forget a saved profile: end its session on the server, delete its
    /// token, and purge its cache. Forgetting the active profile signs out
    /// and then switches to the most recently used remaining profile, so a
    /// household's other sign-ins are never lost to one sign-out.
    public func forgetProfile(_ id: ProfileID) async {
        if id == activeProfileID {
            await disconnect()
            return
        }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        // Best effort, like sign-out: a server that can't be reached still
        // has the profile forgotten here
        let profileClient = makeClient(makeConfiguration(serverURL: profile.serverURL), profile)
        await profileClient.signOut()

        try? sessionStore.remove(id)
        if let cache {
            await cache.purge(scope: CacheScope(serverURL: profile.serverURL, userID: profile.userID))
        }
        reloadProfiles()
    }

    /// Restore a previously saved session from the Keychain, if any.
    ///
    /// With a cache hit (this server + user's libraries were persisted by a
    /// previous run), the session is published immediately and validated in
    /// the background — Home renders from cache without waiting on a round
    /// trip, and works offline. Without one, the blocking validate-first
    /// flow runs as before.
    public func restoreSession() async {
        defer { hasAttemptedRestore = true }
        guard state == .disconnected else { return }
        reloadProfiles()
        guard let saved = sessionStore.load() else { return }

        errorMessage = nil
        state = .connecting

        // Reflect the restored server in the form
        serverURL = saved.serverURL.absoluteString

        let scope = CacheScope(serverURL: saved.serverURL, userID: saved.userID)
        let restoredClient = wrapped(
            makeClient(makeConfiguration(serverURL: saved.serverURL), saved),
            scope: scope,
        )
        self.client = restoredClient

        if let cache {
            if let cachedLibraries = await cache.read([Library].self, scope: scope, key: .libraries),
               state == .connecting
            {
                // Instant connect: publish now, verify in the background
                libraries = cachedLibraries.filter(\.isBrowsable)
                liveTVLibrary = cachedLibraries.liveTV
                connectedUser = await cache.read(User.self, scope: scope, key: .currentUser)
                if let name = connectedUser?.name {
                    username = name
                }
                state = .connected
                session?.setClient(restoredClient, scopedCache: ScopedCache(store: cache, scope: scope))
                refreshLibraryCounts(client: restoredClient)
                validateInBackground(client: restoredClient, cache: cache, scope: scope)
                return
            }
        }

        do {
            // Validate the saved token, and the server version alongside it,
            // before treating the session as live
            async let serverInfo = try? restoredClient.fetchPublicServerInfo()
            async let currentUser = restoredClient.fetchCurrentUser()
            let info = await serverInfo
            try Self.requireSupported(info)
            let user = try await currentUser
            try await completeConnection(client: restoredClient, user: user)
            username = user.name
            refreshActiveProfileLabels(user: user, serverName: info?.serverName)
        } catch {
            if let message = Self.endedSessionMessage(for: error) {
                // The session can never work again: forget the profile and
                // fall back to the form, which lists any others still saved
                try? sessionStore.clearSession()
                reloadProfiles()
                if let cache {
                    await cache.purge(scope: scope)
                }
                errorMessage = message
            } else {
                // Transient failure (network, server down): keep the saved session
                errorMessage = error.localizedDescription
            }
            state = .disconnected
            client = nil
        }
    }

    /// Ends a restore on a server below the minimum. A version that couldn't
    /// be read (nil) passes: like a transient token-check failure, it keeps
    /// the session.
    private static func requireSupported(_ serverInfo: ServerInfo?) throws {
        if let serverInfo, !serverInfo.isSupported {
            throw APIError.unsupportedServerVersion(serverInfo.version)
        }
    }

    /// The form's message when a restore failure means the saved session can
    /// never work again (revoked token, server too old); nil for a transient
    /// failure, which keeps the session.
    private static func endedSessionMessage(for error: any Error) -> String? {
        switch error as? APIError {
        case .unauthorized:
            String(localized: "signIn.error.sessionExpired", bundle: #bundle, comment: "Shown on the sign-in form when the saved sign-in was revoked by the server.")
        case .unsupportedServerVersion:
            error.localizedDescription
        default:
            nil
        }
    }

    /// Verify an instantly-restored session against the server. Success
    /// refreshes the user and libraries (the caching client re-persists
    /// them); a 401 (token revoked) or a server below the minimum version
    /// tears the provisional session down exactly as a blocking restore
    /// would have, plus a cache purge; any other failure leaves the session
    /// standing on cached content — the server may just be rebooting, and
    /// playback will surface its own errors.
    private func validateInBackground(
        client: any JellyfinClientProtocol,
        cache: MediaCacheStore,
        scope: CacheScope,
    ) {
        isValidating = true
        validationTask = Task { [weak self] in
            do {
                async let serverInfo = try? client.fetchPublicServerInfo()
                async let currentUser = client.fetchCurrentUser()
                let info = await serverInfo
                try Self.requireSupported(info)
                let user = try await currentUser
                let all = try await client.getLibraries()
                let fresh = all.filter(\.isBrowsable)
                guard let self, !Task.isCancelled, state == .connected else { return }
                connectedUser = user
                username = user.name
                refreshActiveProfileLabels(user: user, serverName: info?.serverName)
                libraries = fresh
                liveTVLibrary = all.liveTV
                refreshLibraryCounts(client: client)
                isValidating = false
                await cache.purgeStaleDetails(scope: scope)
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard let message = Self.endedSessionMessage(for: error) else {
                    isValidating = false
                    return
                }
                guard state == .connected else { return }
                // Unpublish first so no screen starts work on the scope, and
                // re-enable Connect last: a client made before the purge
                // has its cache writes dropped, for its whole session.
                session?.clearClient()
                self.client = nil
                try? sessionStore.clearSession()
                reloadProfiles()
                await cache.purge(scope: scope)
                await clearArtworkCaches()
                errorMessage = message
                state = .disconnected
                connectedUser = nil
                libraries = []
                liveTVLibrary = nil
                libraryCounts = [:]
                isValidating = false
            }
        }
    }

    /// Sign out of the active profile: end its session on the server, forget
    /// it, and purge its cache. Switches to the most recently used remaining
    /// profile when there is one.
    public func disconnect() async {
        validationTask?.cancel()
        validationTask = nil
        countsTask?.cancel()
        countsTask = nil
        isValidating = false

        // Resolve whose cache to purge before the identities are torn down.
        // The saved session is authoritative; the live client covers the
        // edge where the Keychain write failed at connect time.
        let scopeToPurge: CacheScope? = {
            if let saved = sessionStore.load() {
                return CacheScope(serverURL: saved.serverURL, userID: saved.userID)
            }
            if let client, let user = client.currentUser {
                return CacheScope(serverURL: client.serverURL, userID: user.id)
            }
            return nil
        }()

        if let client {
            await client.signOut()
        }

        // Remove the saved session; the device ID is intentionally preserved
        try? sessionStore.clearSession()

        // Sign-out is a privacy boundary: the next account on this device
        // must not inherit this one's cached library
        if let cache, let scopeToPurge {
            await cache.purge(scope: scopeToPurge)
        }
        await clearArtworkCaches()

        client = nil
        connectedUser = nil
        libraries = []
        liveTVLibrary = nil
        libraryCounts = [:]
        state = .disconnected
        errorMessage = nil
        session?.clearClient()
        reloadProfiles()

        // Signing out of one profile must not lose the household's other
        // sign-ins: carry on as the most recently used one that remains
        if let next = profiles.first {
            await switchToProfile(next.id)
        }
    }

    // MARK: - Helpers

    /// Artwork (posters, logos, chapter images, trickplay tiles) is shared
    /// across accounts, so an ended session's goes whole: encoded bytes and
    /// decoded images
    private func clearArtworkCaches() async {
        urlCache.removeAllCachedResponses()
        await artworkLoader.removeAllImages()
    }

    /// Parse and validate the server URL
    private func parseServerURL(_ urlString: String) -> URL? {
        var cleanedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add https:// if no scheme provided
        if !cleanedURL.contains("://") {
            cleanedURL = "https://\(cleanedURL)"
        }

        guard let url = URL(string: cleanedURL) else {
            return nil
        }

        // Ensure we have a valid host
        guard url.host != nil else {
            return nil
        }

        return url
    }

    /// Device name based on platform
    private var deviceName: String {
        #if os(tvOS)
            return "Apple TV"
        #elseif os(visionOS)
            return "Apple Vision Pro"
        #else
            return "Apple Device"
        #endif
    }

    /// Persistent device ID, generated once and stored in the Keychain
    private var deviceID: String {
        sessionStore.deviceID()
    }

    /// Build a client configuration for this device. The version is the one
    /// Settings shows, so the server's device list and activity log name the
    /// build; the client name comes from JellyfinClientConfiguration's default.
    private func makeConfiguration(serverURL: URL) -> JellyfinClientConfiguration {
        JellyfinClientConfiguration(
            serverURL: serverURL,
            clientVersion: AppVersion.text() ?? "unknown",
            deviceName: deviceName,
            deviceID: deviceID,
        )
    }

    /// Awaits completion of the in-flight background validation, if any.
    ///
    /// Intended for tests to observe results deterministically without sleeping.
    func awaitValidation() async {
        await validationTask?.value
    }

    /// Awaits completion of the in-flight library count fetch, if any.
    ///
    /// Intended for tests to observe results deterministically without sleeping.
    /// Re-read the server's library list and publish it only if the set of
    /// ids changed. Nothing on the client can observe a library added on the
    /// server, so Home's idle-floor drain asks here; `RootView` turns a
    /// changed list into a `.libraries` refresh (#236).
    public func refreshLibraries() async {
        guard state == .connected, let client else { return }
        guard let all = try? await client.getLibraries() else { return }
        // Written only on a change: `RootView` observes it, and this runs on
        // every idle refresh.
        if liveTVLibrary != all.liveTV {
            liveTVLibrary = all.liveTV
        }
        let fresh = all.filter(\.isBrowsable)
        guard Set(fresh.map(\.id)) != Set(libraries.map(\.id)) else { return }
        libraries = fresh
        refreshLibraryCounts(client: client)
    }

    func awaitLibraryCounts() async {
        await countsTask?.value
    }

    /// Fetch each library's real size in parallel and publish the merged
    /// result, replacing the dictionary whole so counts from a previous
    /// library list never linger. A library whose fetch fails gets no entry.
    private func refreshLibraryCounts(client: any JellyfinClientProtocol) {
        countsTask?.cancel()
        let libraries = libraries
        countsTask = Task { [weak self] in
            let counts = await withTaskGroup(of: (String, Int?).self) { group in
                for library in libraries {
                    group.addTask {
                        await (library.id, try? client.getLibraryItemCount(libraryId: library.id))
                    }
                }
                var merged: [String: Int] = [:]
                for await (id, count) in group {
                    if let count {
                        merged[id] = count
                    }
                }
                return merged
            }
            guard let self, !Task.isCancelled, state == .connected else { return }
            libraryCounts = counts
        }
    }

    /// Wrap a freshly-built client so its responses feed the cache and the
    /// user-state overlay; without a cache the client passes through
    /// untouched. A restored session passes its scope so writes work during
    /// the validation window, before the wrapped client has fetched its
    /// user.
    private func wrapped(
        _ client: any JellyfinClientProtocol,
        scope: CacheScope? = nil,
    ) -> any JellyfinClientProtocol {
        guard let cache else { return client }
        return CachingJellyfinClient(
            wrapping: client,
            cache: cache,
            scope: scope,
            userState: session?.userState,
        )
    }

    /// Finish a successful authentication: prove the connection by fetching
    /// libraries, then surface the connected state and publish the client
    private func completeConnection(client: any JellyfinClientProtocol, user: User) async throws {
        let all = try await client.getLibraries()
        publishConnection(client: client, user: user, libraries: all)
    }

    /// Surface the connected state and publish the client app-wide
    private func publishConnection(client: any JellyfinClientProtocol, user: User, libraries all: [Library]) {
        libraries = all.filter(\.isBrowsable)
        liveTVLibrary = all.liveTV
        connectedUser = user
        state = .connected
        let scopedCache = cache.map {
            ScopedCache(store: $0, scope: CacheScope(serverURL: client.serverURL, userID: user.id))
        }
        session?.setClient(client, scopedCache: scopedCache)
        refreshLibraryCounts(client: client)
    }

    /// Save the session to the Keychain as the active profile, so it can be
    /// restored on next launch and switched back to later
    private func persistSession(
        for client: any JellyfinClientProtocol,
        serverURL: URL,
        user: User,
        serverName: String,
    ) {
        guard let accessToken = client.accessToken else { return }

        // A failed Keychain write should not fail a live connection; the
        // session simply won't be restored on the next launch
        try? sessionStore.save(
            SavedSession(
                serverURL: serverURL,
                userID: user.id,
                accessToken: accessToken,
                userName: user.name,
                serverName: serverName,
            ),
        )
        reloadProfiles()
    }

    /// Bring the active profile's user and server names up to date once the
    /// server has confirmed them. Profiles saved before names were stored get
    /// them here, and a renamed user or server stops showing the old name.
    private func refreshActiveProfileLabels(user: User, serverName: String?) {
        guard let active = sessionStore.load(), active.userID == user.id else { return }
        let resolvedServerName = serverName ?? active.serverName
        guard active.userName != user.name || active.serverName != resolvedServerName else { return }
        try? sessionStore.save(
            SavedSession(
                serverURL: active.serverURL,
                userID: active.userID,
                accessToken: active.accessToken,
                userName: user.name,
                serverName: resolvedServerName,
            ),
        )
        reloadProfiles()
    }

    /// Re-read the saved profiles after the store changes
    private func reloadProfiles() {
        profiles = sessionStore.profiles()
        activeProfileID = sessionStore.load()?.id
    }

    /// The form's server URL, or nil with `errorMessage` set when it can't be
    /// read as a web address
    private func validatedServerURL() -> URL? {
        guard let url = parseServerURL(serverURL) else {
            errorMessage = String(localized: "signIn.error.invalidURL", bundle: #bundle, comment: "Shown under the sign-in form when the server address can't be read as a web address.")
            return nil
        }
        return url
    }

    /// Sign in with the form's credentials. A too-old server is refused
    /// before credentials are sent, so it never gets a session to save.
    private func signIn(with client: any JellyfinClientProtocol) async throws -> (User, serverName: String) {
        let serverInfo = try await client.fetchPublicServerInfo()
        guard serverInfo.isSupported else {
            throw APIError.unsupportedServerVersion(serverInfo.version)
        }
        let user = try await client.authenticate(username: username, password: password)
        return (user, serverInfo.serverName)
    }

    /// End the current session in this app only: no sign-out request, no
    /// cache purge, and the saved token is kept. Used to leave a profile
    /// that stays saved.
    private func endSessionLocally() {
        validationTask?.cancel()
        validationTask = nil
        countsTask?.cancel()
        countsTask = nil
        isValidating = false
        session?.clearClient()
        client = nil
        connectedUser = nil
        libraries = []
        liveTVLibrary = nil
        libraryCounts = [:]
        state = .disconnected
        errorMessage = nil
    }
}

private extension [Library] {
    var liveTV: Library? {
        first { $0.collectionType == .livetv }
    }
}

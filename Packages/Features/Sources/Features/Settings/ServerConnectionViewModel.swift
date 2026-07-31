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

    // MARK: - Private

    /// The Jellyfin client instance
    private var client: (any JellyfinClientProtocol)?

    /// The metadata cache; nil (previews, tests without one) disables both
    /// instant connect and write-through, restoring the blocking flow
    private let cache: MediaCacheStore?

    /// The in-flight background validation of an instantly-restored session
    private var validationTask: Task<Void, Never>?

    /// Shared session to publish the client into after connecting
    private weak var session: AppSession?

    /// Persisted session storage (Keychain-backed in production)
    private let sessionStore: any SessionStoring

    /// Factory for building clients (injectable for tests); the saved session
    /// is non-nil when restoring rather than authenticating fresh
    private let makeClient: @MainActor (
        JellyfinClientConfiguration, _ restoredSession: SavedSession?,
    ) -> any JellyfinClientProtocol

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
    ) {
        self.sessionStore = sessionStore
        self.makeClient = makeClient
        self.cache = cache
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

        // Validate URL
        guard let url = parseServerURL(serverURL) else {
            errorMessage = "Invalid server URL"
            return
        }

        // Start connecting
        state = .connecting

        // Create client
        let newClient = wrapped(makeClient(makeConfiguration(serverURL: url), nil))
        self.client = newClient

        // Authenticate
        state = .authenticating

        do {
            let user = try await newClient.authenticate(username: username, password: password)
            try await completeConnection(client: newClient, user: user)
            persistSession(for: newClient, serverURL: url, user: user)
        } catch {
            errorMessage = error.localizedDescription
            state = .disconnected
            client = nil
        }
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
                connectedUser = await cache.read(User.self, scope: scope, key: .currentUser)
                if let name = connectedUser?.name {
                    username = name
                }
                state = .connected
                session?.setClient(restoredClient, scopedCache: ScopedCache(store: cache, scope: scope))
                validateInBackground(client: restoredClient, cache: cache, scope: scope)
                return
            }
        }

        do {
            // Validate the saved token before treating the session as live
            let user = try await restoredClient.fetchCurrentUser()
            try await completeConnection(client: restoredClient, user: user)
            username = user.name
        } catch APIError.unauthorized {
            // The token is no longer valid: clear it and fall back to the form
            try? sessionStore.clearSession()
            if let cache {
                await cache.purge(scope: CacheScope(serverURL: saved.serverURL, userID: saved.userID))
            }
            errorMessage = "Your session has expired. Please sign in again."
            state = .disconnected
            client = nil
        } catch {
            // Transient failure (network, server down): keep the saved session
            errorMessage = error.localizedDescription
            state = .disconnected
            client = nil
        }
    }

    /// Verify an instantly-restored session against the server. Success
    /// refreshes the user and libraries (the caching client re-persists
    /// them); a 401 means the token was revoked, so the provisional session
    /// tears down exactly as a blocking restore would have, plus a cache
    /// purge; any other failure leaves the session standing on cached
    /// content — the server may just be rebooting, and playback will surface
    /// its own errors.
    private func validateInBackground(
        client: any JellyfinClientProtocol,
        cache: MediaCacheStore,
        scope: CacheScope,
    ) {
        isValidating = true
        validationTask = Task { [weak self] in
            do {
                let user = try await client.fetchCurrentUser()
                let fresh = try await client.getLibraries().filter(\.isBrowsable)
                guard let self, !Task.isCancelled, state == .connected else { return }
                connectedUser = user
                username = user.name
                libraries = fresh
                isValidating = false
                await cache.purgeStaleDetails(scope: scope)
            } catch APIError.unauthorized {
                guard let self, !Task.isCancelled, state == .connected else { return }
                try? sessionStore.clearSession()
                await cache.purge(scope: scope)
                errorMessage = "Your session has expired. Please sign in again."
                state = .disconnected
                self.client = nil
                connectedUser = nil
                libraries = []
                isValidating = false
                session?.clearClient()
            } catch {
                guard let self, !Task.isCancelled else { return }
                isValidating = false
            }
        }
    }

    /// Disconnect from the server
    public func disconnect() async {
        validationTask?.cancel()
        validationTask = nil
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

        client = nil
        connectedUser = nil
        libraries = []
        state = .disconnected
        errorMessage = nil
        session?.clearClient()
    }

    // MARK: - Helpers

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

    /// Build a client configuration for this device; client name and version
    /// come from JellyfinClientConfiguration's defaults
    private func makeConfiguration(serverURL: URL) -> JellyfinClientConfiguration {
        JellyfinClientConfiguration(
            serverURL: serverURL,
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
        libraries = try await client.getLibraries().filter(\.isBrowsable)
        connectedUser = user
        state = .connected
        let scopedCache = cache.map {
            ScopedCache(store: $0, scope: CacheScope(serverURL: client.serverURL, userID: user.id))
        }
        session?.setClient(client, scopedCache: scopedCache)
    }

    /// Save the session to the Keychain so it can be restored on next launch
    private func persistSession(for client: any JellyfinClientProtocol, serverURL: URL, user: User) {
        guard let accessToken = client.accessToken else { return }

        // A failed Keychain write should not fail a live connection; the
        // session simply won't be restored on the next launch
        try? sessionStore.save(
            SavedSession(serverURL: serverURL, userID: user.id, accessToken: accessToken),
        )
    }
}

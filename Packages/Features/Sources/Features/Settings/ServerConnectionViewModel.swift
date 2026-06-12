import Foundation
import Observation
import JellyfinKit

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

    /// Shared session to publish the client into after connecting
    private weak var session: AppSession?

    /// Persisted session storage (Keychain-backed in production)
    private let sessionStore: any SessionStoring

    /// Factory for building clients (injectable for tests)
    private let makeClient: @MainActor (
        JellyfinClientConfiguration, _ accessToken: String?, _ userID: String?
    ) -> any JellyfinClientProtocol

    // MARK: - Initialization

    public init(
        sessionStore: any SessionStoring = SessionStore(),
        makeClient: @escaping @MainActor (
            JellyfinClientConfiguration, String?, String?
        ) -> any JellyfinClientProtocol = { configuration, accessToken, userID in
            JellyfinClient(configuration: configuration, accessToken: accessToken, userID: userID)
        }
    ) {
        self.sessionStore = sessionStore
        self.makeClient = makeClient
    }

    /// Attach the shared session so the connected client can be published app-wide
    public func attach(session: AppSession) {
        self.session = session
    }

    // MARK: - Actions

    /// Connect to the server and authenticate
    public func connect() async {
        // Clear previous error
        errorMessage = nil

        // Validate URL
        guard let url = parseServerURL(serverURL) else {
            errorMessage = "Invalid server URL"
            return
        }

        // Start connecting
        state = .connecting

        // Create client configuration
        let configuration = JellyfinClientConfiguration(
            serverURL: url,
            clientName: "Jelly Shark",
            clientVersion: "0.0.1",
            deviceName: deviceName,
            deviceID: deviceID
        )

        // Create client
        let newClient = makeClient(configuration, nil, nil)
        self.client = newClient

        // Authenticate
        state = .authenticating

        do {
            let user = try await newClient.authenticate(username: username, password: password)
            connectedUser = user

            // Fetch libraries to prove we're connected
            libraries = try await newClient.getLibraries()

            state = .connected
            session?.setClient(newClient)
            persistSession(for: newClient, serverURL: url, user: user)
        } catch let error as APIError {
            errorMessage = error.localizedDescription
            state = .disconnected
            client = nil
        } catch {
            errorMessage = error.localizedDescription
            state = .disconnected
            client = nil
        }
    }

    /// Restore a previously saved session from the Keychain, if any
    public func restoreSession() async {
        guard state == .disconnected else { return }
        guard let saved = sessionStore.load() else { return }

        errorMessage = nil
        state = .connecting

        // Reflect the restored server in the form
        serverURL = saved.serverURL.absoluteString

        let configuration = JellyfinClientConfiguration(
            serverURL: saved.serverURL,
            clientName: "Jelly Shark",
            clientVersion: "0.0.1",
            deviceName: deviceName,
            deviceID: deviceID
        )

        let restoredClient = makeClient(configuration, saved.accessToken, saved.userID)
        self.client = restoredClient

        do {
            // Validate the saved token before treating the session as live
            let user = try await restoredClient.fetchCurrentUser()
            connectedUser = user
            username = user.name

            libraries = try await restoredClient.getLibraries()

            state = .connected
            session?.setClient(restoredClient)
        } catch APIError.unauthorized {
            // The token is no longer valid: clear it and fall back to the form
            try? sessionStore.clearSession()
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

    /// Disconnect from the server
    public func disconnect() async {
        if let client = client {
            await client.signOut()
        }

        // Remove the saved session; the device ID is intentionally preserved
        try? sessionStore.clearSession()

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

    /// Save the session to the Keychain so it can be restored on next launch
    private func persistSession(for client: any JellyfinClientProtocol, serverURL: URL, user: User) {
        guard let accessToken = client.accessToken else { return }

        // A failed Keychain write should not fail a live connection; the
        // session simply won't be restored on the next launch
        try? sessionStore.save(
            SavedSession(serverURL: serverURL, userID: user.id, accessToken: accessToken)
        )
    }
}

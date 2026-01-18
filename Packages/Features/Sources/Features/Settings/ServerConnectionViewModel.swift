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
    private var client: JellyfinClient?

    // MARK: - Initialization

    public init() {}

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
        let newClient = JellyfinClient(configuration: configuration)
        self.client = newClient

        // Authenticate
        state = .authenticating

        do {
            let user = try await newClient.authenticate(username: username, password: password)
            connectedUser = user

            // Fetch libraries to prove we're connected
            libraries = try await newClient.getLibraries()

            state = .connected
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

    /// Disconnect from the server
    public func disconnect() async {
        if let client = client {
            await client.signOut()
        }

        client = nil
        connectedUser = nil
        libraries = []
        state = .disconnected
        errorMessage = nil
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

    /// Persistent device ID (for now just use a generated UUID)
    private var deviceID: String {
        // TODO: Store in Keychain for persistence
        UUID().uuidString
    }
}

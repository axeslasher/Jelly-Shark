import Foundation

/// A persisted Jellyfin session that can be restored on a later launch
public struct SavedSession: Codable, Sendable, Equatable {
    /// The server URL the session belongs to
    public let serverURL: URL

    /// The authenticated user's ID
    public let userID: String

    /// The access token issued by the server
    public let accessToken: String

    public init(serverURL: URL, userID: String, accessToken: String) {
        self.serverURL = serverURL
        self.userID = userID
        self.accessToken = accessToken
    }
}

/// Abstraction over session persistence so consumers can be tested
/// with an in-memory double
public protocol SessionStoring: Sendable {
    /// Persist the session, replacing any existing one
    func save(_ session: SavedSession) throws

    /// Load the saved session, if any
    func load() -> SavedSession?

    /// Remove the saved session (does NOT remove the device ID)
    func clearSession() throws

    /// A stable device identifier, generated once and reused forever
    func deviceID() -> String
}

/// Keychain-backed session store
///
/// The session (token, user ID, server URL) is stored as a single item so it
/// is saved and cleared atomically. The device ID lives under its own key so
/// it survives `clearSession()` and the server sees one consistent device.
public struct SessionStore: SessionStoring, Sendable {
    private let keychain: KeychainStore

    private static let sessionKey = "session"
    private static let deviceIDKey = "deviceID"

    public init(service: String = "com.jellyshark.app") {
        self.keychain = KeychainStore(service: service)
    }

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public func save(_ session: SavedSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.setData(data, for: Self.sessionKey)
    }

    public func load() -> SavedSession? {
        // A missing or unreadable session behaves like "no session" so the
        // app falls back to the connection form instead of failing at launch
        guard let data = try? keychain.data(for: Self.sessionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    public func clearSession() throws {
        try keychain.delete(Self.sessionKey)
    }

    public func deviceID() -> String {
        if let existing = try? keychain.string(for: Self.deviceIDKey), !existing.isEmpty {
            return existing
        }

        // If the write fails the ID still works for this run; the next
        // launch will simply generate a new one
        let newID = UUID().uuidString
        try? keychain.setString(newID, for: Self.deviceIDKey)
        return newID
    }
}

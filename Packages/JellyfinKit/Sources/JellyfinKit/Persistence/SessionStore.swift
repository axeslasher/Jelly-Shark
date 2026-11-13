import Foundation

/// Identifies a saved profile: one user on one server. Two sign-ins for the
/// same user on the same server are the same profile.
public struct ProfileID: Codable, Hashable, Sendable {
    public let serverURL: URL
    public let userID: String

    public init(serverURL: URL, userID: String) {
        self.serverURL = serverURL
        self.userID = userID
    }
}

/// A persisted Jellyfin session that can be restored on a later launch: one
/// saved profile
public struct SavedSession: Codable, Sendable, Equatable, Identifiable {
    /// The server URL the session belongs to
    public let serverURL: URL

    /// The authenticated user's ID
    public let userID: String

    /// The access token issued by the server
    public let accessToken: String

    /// The user's display name, for labelling the profile. Nil for a session
    /// saved before profiles existed.
    public let userName: String?

    /// The server's display name, for labelling the profile. Nil for a session
    /// saved before profiles existed.
    public let serverName: String?

    public init(
        serverURL: URL,
        userID: String,
        accessToken: String,
        userName: String? = nil,
        serverName: String? = nil,
    ) {
        self.serverURL = serverURL
        self.userID = userID
        self.accessToken = accessToken
        self.userName = userName
        self.serverName = serverName
    }

    public var id: ProfileID {
        ProfileID(serverURL: serverURL, userID: userID)
    }
}

/// Abstraction over session persistence so consumers can be tested
/// with an in-memory double
public protocol SessionStoring: Sendable {
    /// Save the session as a profile and make it the active one. A profile
    /// for the same server and user is replaced, token included.
    func save(_ session: SavedSession) throws

    /// The active profile's session, if one is active
    func load() -> SavedSession?

    /// Every saved profile, most recently used first
    func profiles() -> [SavedSession]

    /// Make a saved profile the active one, keeping its token
    func activate(_ id: ProfileID) throws

    /// Delete one profile and its token. Deleting the active profile leaves
    /// no profile active.
    func remove(_ id: ProfileID) throws

    /// Delete the active profile and its token. Other profiles and the
    /// device ID are kept.
    func clearSession() throws

    /// A stable device identifier, generated once and reused forever
    func deviceID() -> String
}

/// Keychain-backed session store
///
/// Every profile, and which one is active, is stored as a single item so a
/// change is saved atomically: no write can leave the active profile
/// pointing at a token that isn't there. The device ID lives under its own
/// key so it survives every profile change.
///
/// The device ID is shared across profiles on purpose: it identifies this
/// installation, not a user. Jellyfin keeps each user's token on a shared
/// device ID valid when another user signs in (verified on 10.11.11 and
/// 12.4), and its device list shows one row per signed-in user, all under
/// this one ID (verified on 10.11.11).
public struct SessionStore: SessionStoring, Sendable {
    private let keychain: KeychainStore

    private static let profilesKey = "profiles"
    private static let deviceIDKey = "deviceID"

    /// Where a single session lived before profiles. Read once to adopt it
    /// as the first profile, then deleted.
    private static let legacySessionKey = "session"

    /// The stored shape: profiles most recently used first
    private struct ProfileList: Codable {
        var profiles: [SavedSession] = []
        var activeID: ProfileID?
    }

    public init(service: String = "com.jellyshark.app") {
        self.keychain = KeychainStore(service: service)
    }

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public func save(_ session: SavedSession) throws {
        var list = try readListForWriting()
        list.profiles.removeAll { $0.id == session.id }
        list.profiles.insert(session, at: 0)
        list.activeID = session.id
        try write(list)
    }

    public func load() -> SavedSession? {
        let list = readList()
        guard let activeID = list.activeID else { return nil }
        return list.profiles.first { $0.id == activeID }
    }

    public func profiles() -> [SavedSession] {
        readList().profiles
    }

    public func activate(_ id: ProfileID) throws {
        var list = try readListForWriting()
        guard let index = list.profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = list.profiles.remove(at: index)
        list.profiles.insert(profile, at: 0)
        list.activeID = id
        try write(list)
    }

    public func remove(_ id: ProfileID) throws {
        var list = try readListForWriting()
        list.profiles.removeAll { $0.id == id }
        if list.activeID == id {
            list.activeID = nil
        }
        try write(list)
    }

    public func clearSession() throws {
        var list = try readListForWriting()
        guard let activeID = list.activeID else { return }
        list.profiles.removeAll { $0.id == activeID }
        list.activeID = nil
        try write(list)
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

    // MARK: - Storage

    /// The saved profiles. Missing, unreadable or corrupt storage reads as no
    /// profiles, so the app falls back to the sign-in form instead of failing
    /// at launch.
    private func readList() -> ProfileList {
        (try? readListForWriting()) ?? ProfileList()
    }

    /// The saved profiles, for a change that writes them back. A Keychain
    /// failure throws instead of reading as empty: writing a list built from
    /// nothing would delete every other profile's token. Corrupt data still
    /// reads as empty, since nothing in it can be recovered.
    private func readListForWriting() throws -> ProfileList {
        // A Keychain failure is not "nothing saved": adopting the legacy
        // session here could overwrite profiles that do exist
        let stored = try keychain.data(for: Self.profilesKey)
        let list = stored.flatMap { try? JSONDecoder().decode(ProfileList.self, from: $0) } ?? ProfileList()
        return adoptingLegacySession(into: list)
    }

    /// A session saved by a version from before profiles becomes the active
    /// profile, so nobody is signed out by the upgrade.
    ///
    /// Every write deletes the legacy item, so one that exists was saved by an
    /// older version after this one last wrote: the first launch after the
    /// upgrade, or after a downgrade and a sign-in there. Either way it is the
    /// newest sign-in, so it is adopted even when profiles already exist.
    private func adoptingLegacySession(into list: ProfileList) -> ProfileList {
        guard let data = try? keychain.data(for: Self.legacySessionKey),
              let legacy = try? JSONDecoder().decode(SavedSession.self, from: data)
        else {
            return list
        }
        var adopted = list
        adopted.profiles.removeAll { $0.id == legacy.id }
        adopted.profiles.insert(legacy, at: 0)
        adopted.activeID = legacy.id
        // If this write fails the legacy item stays, and the next read adopts
        // it again
        try? write(adopted)
        return adopted
    }

    private func write(_ list: ProfileList) throws {
        let data = try JSONEncoder().encode(list)
        try keychain.setData(data, for: Self.profilesKey)
        // Once the profile list exists the legacy item must not outlive it:
        // a forgotten profile's token would otherwise sit there, and be
        // adopted again if the list were ever lost
        try? keychain.delete(Self.legacySessionKey)
    }
}

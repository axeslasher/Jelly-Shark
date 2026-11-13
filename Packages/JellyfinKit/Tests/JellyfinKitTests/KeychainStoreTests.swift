import Foundation
@testable import JellyfinKit
import Testing

/// Make a store with a unique, test-specific service so tests never touch
/// the production namespace or each other
private func makeTestKeychain() -> KeychainStore {
    KeychainStore(service: "com.jellyshark.tests.\(UUID().uuidString)")
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test("Set and get round-trips a string")
    func setAndGetRoundTrip() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.delete("token") }

        try keychain.setString("secret-value", for: "token")

        #expect(try keychain.string(for: "token") == "secret-value")
    }

    @Test("Reading a missing key returns nil")
    func missingKeyReturnsNil() throws {
        let keychain = makeTestKeychain()

        #expect(try keychain.string(for: "missing") == nil)
        #expect(try keychain.data(for: "missing") == nil)
    }

    @Test("Setting an existing key overwrites the value")
    func overwriteExistingKey() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.delete("token") }

        try keychain.setString("first", for: "token")
        try keychain.setString("second", for: "token")

        #expect(try keychain.string(for: "token") == "second")
    }

    @Test("Delete removes the value")
    func deleteRemovesValue() throws {
        let keychain = makeTestKeychain()

        try keychain.setString("secret-value", for: "token")
        try keychain.delete("token")

        #expect(try keychain.string(for: "token") == nil)
    }

    @Test("Deleting a missing key does not throw")
    func deleteMissingKeyDoesNotThrow() throws {
        let keychain = makeTestKeychain()

        try keychain.delete("missing")
    }
}

@Suite("SessionStore")
struct SessionStoreTests {
    private let serverA = URL(string: "https://demo.jellyfin.org/stable")!
    private let serverB = URL(string: "http://nas.local:8096")!

    private func makeSavedSession(
        server: URL? = nil,
        user: String = "user-1",
        token: String = "token-1",
    ) -> SavedSession {
        SavedSession(
            serverURL: server ?? serverA,
            userID: user,
            accessToken: token,
            userName: "Name of \(user)",
            serverName: "Server",
        )
    }

    private func cleanUp(_ keychain: KeychainStore) {
        try? keychain.delete("profiles")
        try? keychain.delete("session")
        try? keychain.delete("deviceID")
    }

    @Test("save/load round-trips a SavedSession")
    func saveLoadRoundTrip() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        let session = makeSavedSession()
        try store.save(session)

        #expect(store.load() == session)
        #expect(store.profiles() == [session])
    }

    @Test("load returns nil when nothing is saved")
    func loadReturnsNilWhenEmpty() {
        let store = SessionStore(keychain: makeTestKeychain())

        #expect(store.load() == nil)
        #expect(store.profiles().isEmpty)
    }

    @Test("clearSession removes the active profile but preserves the device ID")
    func clearSessionPreservesDeviceID() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        let deviceID = store.deviceID()
        try store.save(makeSavedSession())
        try store.clearSession()

        #expect(store.load() == nil)
        #expect(store.profiles().isEmpty)
        #expect(store.deviceID() == deviceID)
    }

    @Test("deviceID is generated once and stable across store instances")
    func deviceIDIsStable() {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }

        let first = SessionStore(keychain: keychain).deviceID()
        let second = SessionStore(keychain: keychain).deviceID()

        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test("Corrupt profile data loads as no profiles")
    func corruptProfilesLoadAsEmpty() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        try keychain.setData(Data("not json".utf8), for: "profiles")

        #expect(store.load() == nil)
        #expect(store.profiles().isEmpty)
    }

    // MARK: - Profiles

    @Test("Two profiles save, and both restore from a new store instance")
    func twoProfilesPersist() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let first = makeSavedSession()
        let second = makeSavedSession(server: serverB, user: "user-2", token: "token-2")

        try SessionStore(keychain: keychain).save(first)
        try SessionStore(keychain: keychain).save(second)

        let reopened = SessionStore(keychain: keychain)
        #expect(reopened.load() == second)
        #expect(reopened.profiles() == [second, first])
    }

    @Test("Saving the same user on the same server replaces the profile and its token")
    func resavingReplacesProfile() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        try store.save(makeSavedSession(token: "old"))
        try store.save(makeSavedSession(token: "new"))

        #expect(store.profiles().map(\.accessToken) == ["new"])
    }

    @Test("Same user ID on two servers is two profiles")
    func profileIdentityIncludesServer() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        try store.save(makeSavedSession(server: serverA))
        try store.save(makeSavedSession(server: serverB))

        #expect(store.profiles().count == 2)
    }

    @Test("activate switches the active profile, keeps its token, and moves it first")
    func activateKeepsTokenAndReorders() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)
        let first = makeSavedSession()
        let second = makeSavedSession(user: "user-2", token: "token-2")
        try store.save(first)
        try store.save(second)

        try store.activate(first.id)

        #expect(store.load() == first)
        #expect(store.profiles() == [first, second])
    }

    @Test("activate with an unknown profile changes nothing")
    func activateUnknownIsNoOp() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)
        let first = makeSavedSession()
        try store.save(first)

        try store.activate(ProfileID(serverURL: serverB, userID: "nobody"))

        #expect(store.load() == first)
    }

    @Test("remove deletes only that profile's token")
    func removeDeletesOnlyThatProfile() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)
        let first = makeSavedSession()
        let second = makeSavedSession(user: "user-2", token: "token-2")
        try store.save(first)
        try store.save(second)

        try store.remove(first.id)

        #expect(store.load() == second)
        #expect(store.profiles() == [second])
        let raw = try #require(try keychain.data(for: "profiles"))
        #expect(String(decoding: raw, as: UTF8.self).contains("token-1") == false)
    }

    @Test("Removing the active profile leaves the others saved and none active")
    func removeActiveLeavesNoneActive() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)
        let first = makeSavedSession()
        let second = makeSavedSession(user: "user-2", token: "token-2")
        try store.save(first)
        try store.save(second)

        try store.remove(second.id)

        #expect(store.load() == nil)
        #expect(store.profiles() == [first])
    }

    @Test("The device ID survives adding, switching and removing profiles")
    func deviceIDSurvivesProfileChanges() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)
        let deviceID = store.deviceID()
        let first = makeSavedSession()
        let second = makeSavedSession(user: "user-2", token: "token-2")

        try store.save(first)
        try store.save(second)
        try store.activate(first.id)
        try store.remove(first.id)
        try store.clearSession()

        #expect(store.deviceID() == deviceID)
    }

    // MARK: - Upgrade from a single saved session

    /// Writes a session the way the store did before profiles: one item
    /// under "session", with no display names
    private func writeLegacySession(to keychain: KeychainStore) throws {
        let legacyJSON = #"{"serverURL":"https:\/\/demo.jellyfin.org\/stable","userID":"user-1","accessToken":"legacy-token"}"#
        try keychain.setData(Data(legacyJSON.utf8), for: "session")
    }

    @Test("A session saved before profiles is adopted as the active profile")
    func legacySessionIsAdopted() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        try writeLegacySession(to: keychain)

        let store = SessionStore(keychain: keychain)
        let restored = try #require(store.load())

        #expect(restored.serverURL == serverA)
        #expect(restored.userID == "user-1")
        #expect(restored.accessToken == "legacy-token")
        #expect(restored.userName == nil)
        #expect(store.profiles() == [restored])
    }

    @Test("Adopting the legacy session moves it into the profile list and deletes the old item")
    func legacyItemIsDeletedAfterAdoption() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        try writeLegacySession(to: keychain)

        _ = SessionStore(keychain: keychain).load()

        #expect(try keychain.data(for: "session") == nil)
        #expect(try keychain.data(for: "profiles") != nil)
        #expect(SessionStore(keychain: keychain).load()?.accessToken == "legacy-token")
    }

    @Test("A forgotten legacy profile is not adopted again")
    func forgottenLegacyProfileStaysForgotten() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        try writeLegacySession(to: keychain)
        let store = SessionStore(keychain: keychain)

        try store.clearSession()

        #expect(SessionStore(keychain: keychain).load() == nil)
        #expect(SessionStore(keychain: keychain).profiles().isEmpty)
    }

    @Test("Saving a new profile on an upgraded install keeps the adopted one")
    func savingAfterUpgradeKeepsLegacyProfile() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        try writeLegacySession(to: keychain)
        let store = SessionStore(keychain: keychain)

        try store.save(makeSavedSession(server: serverB, user: "user-2", token: "token-2"))

        #expect(store.profiles().map(\.accessToken) == ["token-2", "legacy-token"])
    }
}

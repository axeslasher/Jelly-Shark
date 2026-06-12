import Testing
import Foundation
@testable import JellyfinKit

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
    private func makeSavedSession() -> SavedSession {
        SavedSession(
            serverURL: URL(string: "https://demo.jellyfin.org/stable")!,
            userID: "user-1",
            accessToken: "token-1"
        )
    }

    private func cleanUp(_ keychain: KeychainStore) {
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
    }

    @Test("load returns nil when nothing is saved")
    func loadReturnsNilWhenEmpty() {
        let store = SessionStore(keychain: makeTestKeychain())

        #expect(store.load() == nil)
    }

    @Test("clearSession removes the session but preserves the device ID")
    func clearSessionPreservesDeviceID() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        let deviceID = store.deviceID()
        try store.save(makeSavedSession())
        try store.clearSession()

        #expect(store.load() == nil)
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

    @Test("Corrupt session data loads as nil")
    func corruptSessionLoadsAsNil() throws {
        let keychain = makeTestKeychain()
        defer { cleanUp(keychain) }
        let store = SessionStore(keychain: keychain)

        try keychain.setData(Data("not json".utf8), for: "session")

        #expect(store.load() == nil)
    }
}

@testable import Features
import Foundation
import JellyfinKit
import Testing

// MARK: - In-Memory Session Store

/// In-memory session store that records calls for assertions
final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    var session: SavedSession?
    var storedDeviceID: String?
    var clearSessionCallCount = 0

    func save(_ session: SavedSession) throws {
        self.session = session
    }

    func load() -> SavedSession? {
        session
    }

    func clearSession() throws {
        clearSessionCallCount += 1
        session = nil
    }

    func deviceID() -> String {
        if let storedDeviceID {
            return storedDeviceID
        }
        let newID = UUID().uuidString
        storedDeviceID = newID
        return newID
    }
}

// MARK: - Tests

@Suite("ServerConnectionViewModel")
@MainActor
struct ServerConnectionViewModelTests {
    /// Captures the arguments passed to the view model's client factory
    final class FactoryRecorder {
        var configurations: [JellyfinClientConfiguration] = []
        var restoredSessions: [SavedSession?] = []
    }

    private func makeSavedSession() -> SavedSession {
        SavedSession(
            serverURL: URL(string: "https://demo.jellyfin.org/stable")!,
            userID: "user-1",
            accessToken: "token-1",
        )
    }

    private func makeViewModel(
        store: InMemorySessionStore,
        client: MockJellyfinClient,
        recorder: FactoryRecorder,
    ) -> ServerConnectionViewModel {
        ServerConnectionViewModel(sessionStore: store) { configuration, restored in
            recorder.configurations.append(configuration)
            recorder.restoredSessions.append(restored)
            return client
        }
    }

    @Test("restoreSession with a valid saved session reaches .connected")
    func restoreValidSession() async {
        let store = InMemorySessionStore()
        store.session = makeSavedSession()
        let client = MockJellyfinClient()
        client.librariesResult = .success([Library(id: "lib-1", name: "Movies")])
        let recorder = FactoryRecorder()
        let appSession = AppSession()

        let viewModel = makeViewModel(store: store, client: client, recorder: recorder)
        viewModel.attach(session: appSession)

        await viewModel.restoreSession()

        #expect(viewModel.state == .connected)
        #expect(viewModel.connectedUser?.id == "user-1")
        #expect(viewModel.libraries.count == 1)
        #expect(viewModel.errorMessage == nil)
        #expect(appSession.client != nil)
        #expect(client.fetchCurrentUserCallCount == 1)
        #expect(recorder.restoredSessions == [makeSavedSession()])
        #expect(recorder.configurations[0].serverURL.absoluteString == "https://demo.jellyfin.org/stable")
        #expect(recorder.configurations[0].deviceID == store.deviceID())
    }

    @Test("restoreSession with no saved session is a no-op")
    func restoreWithoutSavedSession() async {
        let store = InMemorySessionStore()
        let recorder = FactoryRecorder()
        let viewModel = makeViewModel(store: store, client: MockJellyfinClient(), recorder: recorder)

        await viewModel.restoreSession()

        #expect(viewModel.state == .disconnected)
        #expect(viewModel.errorMessage == nil)
        #expect(recorder.configurations.isEmpty)
    }

    @Test("restoreSession clears the saved session on an invalid token")
    func restoreClearsSessionOnUnauthorized() async {
        let store = InMemorySessionStore()
        store.session = makeSavedSession()
        let deviceID = store.deviceID()
        let client = MockJellyfinClient()
        client.fetchCurrentUserResult = .failure(APIError.unauthorized)
        let appSession = AppSession()

        let viewModel = makeViewModel(store: store, client: client, recorder: FactoryRecorder())
        viewModel.attach(session: appSession)

        await viewModel.restoreSession()

        #expect(store.session == nil)
        #expect(store.clearSessionCallCount == 1)
        #expect(store.deviceID() == deviceID)
        #expect(viewModel.state == .disconnected)
        #expect(viewModel.errorMessage != nil)
        #expect(appSession.client == nil)
    }

    @Test("restoreSession clears the saved session when the library fetch is unauthorized")
    func restoreClearsSessionOnUnauthorizedLibraryFetch() async {
        let store = InMemorySessionStore()
        store.session = makeSavedSession()
        let client = MockJellyfinClient()
        client.librariesResult = .failure(APIError.unauthorized)

        let viewModel = makeViewModel(store: store, client: client, recorder: FactoryRecorder())

        await viewModel.restoreSession()

        #expect(store.session == nil)
        #expect(viewModel.state == .disconnected)
        #expect(viewModel.connectedUser == nil)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("restoreSession keeps the saved session on a network failure")
    func restoreKeepsSessionOnNetworkFailure() async {
        let store = InMemorySessionStore()
        store.session = makeSavedSession()
        let client = MockJellyfinClient()
        client.fetchCurrentUserResult = .failure(APIError.networkError("offline"))

        let viewModel = makeViewModel(store: store, client: client, recorder: FactoryRecorder())

        await viewModel.restoreSession()

        #expect(store.session != nil)
        #expect(store.clearSessionCallCount == 0)
        #expect(viewModel.state == .disconnected)
        #expect(viewModel.connectedUser == nil)
        #expect(viewModel.errorMessage?.contains("offline") == true)
    }

    @Test("connect() persists the session on success")
    func connectPersistsSession() async {
        let store = InMemorySessionStore()
        let viewModel = makeViewModel(store: store, client: MockJellyfinClient(), recorder: FactoryRecorder())

        await viewModel.connect()

        #expect(viewModel.state == .connected)
        #expect(store.session == SavedSession(
            serverURL: URL(string: "https://demo.jellyfin.org/stable")!,
            userID: "user-1",
            accessToken: "token-1",
        ))
    }

    @Test("disconnect() clears the session but not the device ID")
    func disconnectClearsSessionOnly() async {
        let store = InMemorySessionStore()
        let viewModel = makeViewModel(store: store, client: MockJellyfinClient(), recorder: FactoryRecorder())

        await viewModel.connect()
        let deviceID = store.deviceID()

        await viewModel.disconnect()

        #expect(store.session == nil)
        #expect(store.deviceID() == deviceID)
        #expect(viewModel.state == .disconnected)
    }

    @Test("Device ID is stable across connects")
    func deviceIDIsStableAcrossConnects() async {
        let store = InMemorySessionStore()
        let recorder = FactoryRecorder()
        let viewModel = makeViewModel(store: store, client: MockJellyfinClient(), recorder: recorder)

        await viewModel.connect()
        await viewModel.disconnect()
        await viewModel.connect()

        #expect(recorder.configurations.count == 2)
        #expect(recorder.configurations[0].deviceID == recorder.configurations[1].deviceID)
    }

    @Test("restoreSession is a no-op when already connected")
    func restoreIsNoOpWhenConnected() async {
        let store = InMemorySessionStore()
        let recorder = FactoryRecorder()
        let viewModel = makeViewModel(store: store, client: MockJellyfinClient(), recorder: recorder)

        await viewModel.connect()
        await viewModel.restoreSession()

        #expect(recorder.configurations.count == 1)
    }
}

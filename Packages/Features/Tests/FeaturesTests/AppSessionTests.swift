import DesignSystem
@testable import Features
import Foundation
import JellyfinKit
import Observation
import Testing

@Suite("AppSession")
@MainActor
struct AppSessionTests {
    /// A user is what makes `MockJellyfinClient.isAuthenticated` true, exactly
    /// as `_currentUser` does on the real client.
    private func authenticated() -> MockJellyfinClient {
        let client = MockJellyfinClient()
        client.currentUser = User(id: "u1", name: "Test")
        return client
    }

    @Test("Publishing an authenticated client connects the session")
    func connectsOnAuthenticatedClient() {
        let session = AppSession()
        session.setClient(authenticated())
        #expect(session.isConnected)
    }

    @Test("Clearing the client disconnects the session")
    func disconnectsOnClear() {
        let session = AppSession()
        session.setClient(authenticated())
        session.clearClient()
        #expect(session.isConnected == false)
    }

    /// The instant-connect path publishes a client whose saved token has not
    /// been validated yet. It counts as connected at once, so screens render
    /// from cache instead of waiting on a server that may never answer (#338).
    @Test("A restored client connects on publication, before validation")
    func connectsBeforeValidation() {
        let session = AppSession()
        let client = MockJellyfinClient()
        session.setClient(client)
        #expect(client.isAuthenticated == false)
        #expect(session.isConnected)
    }

    /// The regression guard for the skeleton hang: the flip has to be visible
    /// to Observation. When `isConnected` was computed through the client — a
    /// plain class Observation cannot see into — no reader was invalidated,
    /// so every `.task(id: session.isConnected)` in the app missed the
    /// transition and its screen never started loading.
    @Test("Publishing a client notifies Observation")
    func publicationIsObservable() {
        let session = AppSession()

        final class ChangeFlag: @unchecked Sendable {
            var didChange = false
        }
        let flag = ChangeFlag()
        withObservationTracking {
            _ = session.isConnected
        } onChange: {
            flag.didChange = true
        }

        session.setClient(MockJellyfinClient())

        #expect(flag.didChange)
    }

    // MARK: Background validation of a cache-restored session (#338)

    @Test("A failed background validation leaves the session connected")
    func staysConnectedAfterTransientValidationFailure() async {
        let rig = InstantConnectTests.Rig()
        await rig.seedCache()
        let gate = AsyncGate()
        rig.client.fetchCurrentUserDelay = { try? await gate.wait() }
        rig.client.fetchCurrentUserResult = .failure(APIError.networkError("offline"))

        await rig.viewModel.restoreSession()
        // Connected from cache while the server hasn't answered
        #expect(rig.appSession.isConnected)

        await gate.open()
        await rig.viewModel.awaitValidation()

        #expect(rig.viewModel.state == .connected)
        #expect(rig.appSession.isConnected)
    }

    @Test("A successful background validation keeps the session connected")
    func staysConnectedAfterValidation() async {
        let rig = InstantConnectTests.Rig()
        await rig.seedCache()

        await rig.viewModel.restoreSession()
        await rig.viewModel.awaitValidation()

        #expect(rig.viewModel.state == .connected)
        #expect(rig.appSession.isConnected)
    }

    @Test("A revoked token disconnects the cache-restored session")
    func disconnectsOnRevokedToken() async {
        let rig = InstantConnectTests.Rig()
        await rig.seedCache()
        rig.client.fetchCurrentUserResult = .failure(APIError.unauthorized)

        await rig.viewModel.restoreSession()
        await rig.viewModel.awaitValidation()

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.appSession.isConnected == false)
    }

    /// Home now loads while validation is still in flight. Its fan-out must
    /// not stop a revoked token or a too-old server from ending the session,
    /// and must not change the message the form shows. The end state is
    /// exactly `HomeView`'s Welcome branch: not connected, restore attempted,
    /// state disconnected.
    @Test("Home's load racing validation still ends a revoked or too-old session", arguments: [true, false])
    func homeLoadRacingValidationStillTearsDown(revoked: Bool) async {
        let rig = InstantConnectTests.Rig()
        await rig.seedCache()
        let gate = AsyncGate()
        let expectedMessage: String
        if revoked {
            rig.client.fetchCurrentUserDelay = { try? await gate.wait() }
            rig.client.fetchCurrentUserResult = .failure(APIError.unauthorized)
            // The revoked token is refused on Home's requests too
            rig.client.resumeItemsResult = .failure(APIError.unauthorized)
            rig.client.nextUpItemsResult = .failure(APIError.unauthorized)
            rig.client.latestItemsHandler = { _ in .failure(APIError.unauthorized) }
            expectedMessage = "Your session has expired. Please sign in again."
        } else {
            rig.client.serverInfoDelay = { try? await gate.wait() }
            rig.client.serverInfoResult = .success(ServerInfo(serverName: "Old", version: "10.11.10", id: "server-1"))
            expectedMessage = APIError.unsupportedServerVersion("10.11.10").localizedDescription
        }

        await rig.viewModel.restoreSession()
        #expect(rig.appSession.isConnected)

        // Home loads against the provisional session, as RootView's
        // `.task(id: session.isConnected)` does, before validation answers
        let home = HomeViewModel()
        home.attach(
            client: rig.appSession.client,
            libraries: rig.viewModel.libraries,
            cache: rig.appSession.scopedCache,
            userState: rig.appSession.userState,
        )
        #expect(await home.load())
        #expect(home.isInitialLoading == false)
        if revoked {
            #expect(home.latestStatus.isFailed)
        }

        await gate.open()
        await rig.viewModel.awaitValidation()

        #expect(rig.appSession.isConnected == false)
        #expect(rig.appSession.client == nil)
        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.viewModel.hasAttemptedRestore)
        #expect(rig.viewModel.errorMessage == expectedMessage)
        #expect(rig.store.session == nil)
        #expect(await rig.cache.read(CachedHomeSnapshot.self, scope: rig.scope, key: .homeSnapshot) == nil)

        // A Home load still running when the session ended finishes after the
        // purge, through the ended session's client and cache handle. Its
        // snapshot write must not put the ended session's page back.
        home.forceReload()
        #expect(await home.load())
        #expect(await rig.cache.read(CachedHomeSnapshot.self, scope: rig.scope, key: .homeSnapshot) == nil)
        #expect(await rig.cache.read([Library].self, scope: rig.scope, key: .libraries) == nil)
    }

    /// The purge stops every cache handle made before it. A sign-in after the
    /// teardown, to the same server and user, must get a fresh handle and
    /// cache normally, not have its whole session's writes dropped.
    @Test("A sign-in after a validation teardown caches into the purged scope again")
    func signInAfterTeardownCaches() async {
        // The mock's own URL, so the restored and the new session share a scope
        let client = MockJellyfinClient()
        let scope = CacheScope(serverURL: client.serverURL, userID: "user-1")
        let store = InMemorySessionStore()
        store.session = SavedSession(serverURL: client.serverURL, userID: "user-1", accessToken: "token-1")
        let cache = MediaCacheStore.makeInMemory()
        await cache.write([Library(id: "lib-1", name: "Movies", collectionType: .movies)], scope: scope, key: .libraries)
        client.serverInfoResult = .success(ServerInfo(serverName: "Old", version: "10.11.10", id: "server-1"))
        client.librariesResult = .success([Library(id: "lib-2", name: "Shows", collectionType: .tvshows)])
        let viewModel = ServerConnectionViewModel(sessionStore: store, makeClient: { _, _ in client }, cache: cache)
        viewModel.attach(session: AppSession())

        await viewModel.restoreSession()
        await viewModel.awaitValidation()
        #expect(viewModel.state == .disconnected)
        #expect(await cache.read([Library].self, scope: scope, key: .libraries) == nil)

        // The server is upgraded and the same user signs in again
        client.serverInfoResult = .success(ServerInfo(serverName: "New", version: "10.11.11", id: "server-1"))
        viewModel.serverURL = client.serverURL.absoluteString
        viewModel.username = "demo"
        viewModel.password = "pw"
        await viewModel.connect()

        #expect(viewModel.state == .connected)
        #expect(await cache.read([Library].self, scope: scope, key: .libraries)?.map(\.id) == ["lib-2"])
    }

    @Test("A session ended by validation clears the artwork caches, as sign-out does")
    func validationTeardownClearsArtwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urlCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 1024 * 1024, directory: directory)
        let request = URLRequest(url: URL(string: "https://demo.jellyfin.org/stable/Items/1/Images/Primary")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        urlCache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1, 2, 3])), for: request)

        // The instant-connect rig's wiring, with an artwork cache of its own
        let rig = InstantConnectTests.Rig()
        await rig.seedCache()
        rig.client.fetchCurrentUserResult = .failure(APIError.unauthorized)
        let client = rig.client
        let viewModel = ServerConnectionViewModel(
            sessionStore: rig.store,
            makeClient: { _, _ in client },
            cache: rig.cache,
            urlCache: urlCache,
            artworkLoader: ArtworkLoader(),
        )
        viewModel.attach(session: AppSession())

        await viewModel.restoreSession()
        #expect(urlCache.cachedResponse(for: request) != nil)
        await viewModel.awaitValidation()

        #expect(viewModel.state == .disconnected)
        #expect(urlCache.cachedResponse(for: request) == nil)
    }

    @Test("A server below the minimum disconnects the cache-restored session")
    func disconnectsOnTooOldServer() async {
        let rig = InstantConnectTests.Rig()
        await rig.seedCache()
        rig.client.serverInfoResult = .success(ServerInfo(serverName: "Old", version: "10.11.10", id: "server-1"))

        await rig.viewModel.restoreSession()
        await rig.viewModel.awaitValidation()

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.appSession.isConnected == false)
    }
}

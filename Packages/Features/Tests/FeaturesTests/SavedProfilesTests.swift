@testable import Features
import Foundation
import JellyfinKit
import Testing

/// Saved profiles (#192): adding, switching and forgetting profiles in the
/// connection view model
@Suite("Saved profiles")
@MainActor
struct SavedProfilesTests {
    private let serverA = URL(string: "https://a.example.com")!
    private let serverB = URL(string: "https://b.example.com")!

    /// A view model whose client factory hands out clients in order: a
    /// fresh sign-in takes the next queued mock, and a restore or a forget
    /// gets a client keyed by the saved token, so each profile's client is
    /// observable on its own
    @MainActor
    private final class Rig {
        let store = InMemorySessionStore()
        let session = AppSession()
        var queuedSignIns: [MockJellyfinClient] = []
        var clientsByToken: [String: MockJellyfinClient] = [:]
        var restoredSessions: [SavedSession] = []
        var viewModel: ServerConnectionViewModel!

        init(cache: MediaCacheStore? = nil) {
            viewModel = ServerConnectionViewModel(
                sessionStore: store,
                makeClient: { [unowned self] _, restored in
                    if let restored {
                        restoredSessions.append(restored)
                        return client(forToken: restored.accessToken)
                    }
                    return queuedSignIns.isEmpty ? MockJellyfinClient() : queuedSignIns.removeFirst()
                },
                cache: cache,
            )
            viewModel.attach(session: session)
        }

        func client(forToken token: String) -> MockJellyfinClient {
            if let existing = clientsByToken[token] {
                return existing
            }
            let client = MockJellyfinClient()
            clientsByToken[token] = client
            return client
        }
    }

    private func profile(_ server: URL, user: String, token: String) -> SavedSession {
        SavedSession(serverURL: server, userID: user, accessToken: token, userName: user, serverName: "Server")
    }

    private func signInClient(user: String, token: String) -> MockJellyfinClient {
        let client = MockJellyfinClient()
        client.authenticatedUserID = user
        client.issuedAccessToken = token
        return client
    }

    /// A rig signed in as user-1 on server A through the form
    private func signedInRig() async -> Rig {
        let rig = Rig()
        rig.queuedSignIns = [signInClient(user: "user-1", token: "token-1")]
        rig.viewModel.serverURL = serverA.absoluteString
        rig.viewModel.username = "user-1"
        await rig.viewModel.connect()
        return rig
    }

    // MARK: - Add Profile

    @Test("Adding a profile keeps the first one saved and makes the new one active")
    func addProfileKeepsFirst() async {
        let rig = await signedInRig()
        let firstConnection = rig.session.connectionID
        let second = signInClient(user: "user-2", token: "token-2")
        rig.queuedSignIns = [second]
        rig.viewModel.serverURL = serverB.absoluteString
        rig.viewModel.username = "user-2"
        rig.viewModel.password = "pw"

        let added = await rig.viewModel.addProfile()

        #expect(added)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.viewModel.connectedUser?.id == "user-2")
        #expect(rig.session.client as? MockJellyfinClient === second)
        #expect(rig.session.connectionID != firstConnection)
        #expect(rig.store.profiles().map(\.accessToken) == ["token-2", "token-1"])
        #expect(rig.viewModel.activeProfile?.userID == "user-2")
        #expect(rig.viewModel.otherProfiles.map(\.userID) == ["user-1"])
        #expect(rig.viewModel.password.isEmpty)
    }

    @Test("Adding a profile does not sign the current profile out")
    func addProfileDoesNotSignOutCurrent() async throws {
        let rig = await signedInRig()
        let first = try #require(rig.session.client as? MockJellyfinClient)
        rig.queuedSignIns = [signInClient(user: "user-2", token: "token-2")]

        await rig.viewModel.addProfile()

        #expect(first.signOutCallCount == 0)
    }

    @Test("A failed Add Profile sign-in leaves the current session untouched")
    func failedAddProfileKeepsCurrent() async throws {
        let rig = await signedInRig()
        let current = try #require(rig.session.client as? MockJellyfinClient)
        let connection = rig.session.connectionID
        let failing = MockJellyfinClient()
        failing.authenticateError = APIError.unauthorized
        rig.queuedSignIns = [failing]

        let added = await rig.viewModel.addProfile()

        #expect(!added)
        #expect(rig.viewModel.errorMessage != nil)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.session.client as? MockJellyfinClient === current)
        #expect(rig.session.connectionID == connection)
        #expect(rig.store.profiles().map(\.userID) == ["user-1"])
    }

    @Test("Add Profile whose libraries fail ends the new token and keeps the current session")
    func addProfileLibraryFailureSignsOutNewToken() async throws {
        let rig = await signedInRig()
        let current = try #require(rig.session.client as? MockJellyfinClient)
        let second = signInClient(user: "user-2", token: "token-2")
        second.librariesResult = .failure(APIError.serverError(statusCode: 500))
        rig.queuedSignIns = [second]

        let added = await rig.viewModel.addProfile()

        #expect(!added)
        #expect(second.signOutCallCount == 1)
        #expect(rig.session.client as? MockJellyfinClient === current)
        #expect(rig.store.profiles().map(\.userID) == ["user-1"])
    }

    // MARK: - Switch

    @Test("Switching restores the other profile with its saved token and keeps the first")
    func switchRestoresOtherProfile() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        rig.store.session = first
        rig.store.session = second
        await rig.viewModel.restoreSession()
        let secondClient = rig.client(forToken: "token-2")
        let connection = rig.session.connectionID

        await rig.viewModel.switchToProfile(first.id)

        #expect(rig.viewModel.state == .connected)
        #expect(rig.restoredSessions.last == first)
        #expect(rig.session.client as? MockJellyfinClient === rig.client(forToken: "token-1"))
        #expect(rig.session.connectionID != connection)
        #expect(secondClient.signOutCallCount == 0)
        #expect(rig.store.profiles().map(\.userID) == ["user-1", "user-2"])
        #expect(rig.viewModel.activeProfileID == first.id)
    }

    @Test("Switching to the active connected profile does nothing")
    func switchToActiveIsNoOp() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        rig.store.session = first
        await rig.viewModel.restoreSession()
        let connection = rig.session.connectionID

        await rig.viewModel.switchToProfile(first.id)

        #expect(rig.session.connectionID == connection)
        #expect(rig.restoredSessions.count == 1)
    }

    @Test("Choosing the active profile while disconnected retries its restore")
    func switchToActiveWhileDisconnectedRetries() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        rig.store.session = first
        rig.client(forToken: "token-1").fetchCurrentUserResult = .failure(APIError.networkError("offline"))
        await rig.viewModel.restoreSession()
        #expect(rig.viewModel.state == .disconnected)
        rig.client(forToken: "token-1").fetchCurrentUserResult = .success(User(id: "user-1", name: "user-1"))

        await rig.viewModel.switchToProfile(first.id)

        #expect(rig.viewModel.state == .connected)
    }

    // MARK: - Forget

    @Test("Forgetting another profile ends its session on the server and deletes only its token")
    func forgetInactiveProfile() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        rig.store.session = first
        rig.store.session = second
        await rig.viewModel.restoreSession()
        let activeClient = rig.client(forToken: "token-2")

        await rig.viewModel.forgetProfile(first.id)

        #expect(rig.client(forToken: "token-1").signOutCallCount == 1)
        #expect(rig.restoredSessions.last == first)
        #expect(activeClient.signOutCallCount == 0)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.store.profiles() == [second])
        #expect(rig.viewModel.profiles == [second])
    }

    @Test("Signing out with another profile saved switches to it")
    func signOutSwitchesToRemainingProfile() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        rig.store.session = first
        rig.store.session = second
        await rig.viewModel.restoreSession()

        await rig.viewModel.disconnect()

        #expect(rig.client(forToken: "token-2").signOutCallCount == 1)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.session.client as? MockJellyfinClient === rig.client(forToken: "token-1"))
        #expect(rig.store.profiles().map(\.id) == [first.id])
        #expect(rig.viewModel.activeProfileID == first.id)
    }

    @Test("A restore fills in names a profile saved before profiles existed is missing")
    func restoreRefreshesProfileLabels() async throws {
        let rig = Rig()
        let legacy = SavedSession(serverURL: serverA, userID: "user-1", accessToken: "token-1")
        rig.store.session = legacy

        await rig.viewModel.restoreSession()

        let refreshed = try #require(rig.store.load())
        #expect(refreshed.userName == "demo")
        #expect(refreshed.serverName == "Mock")
        #expect(refreshed.accessToken == "token-1")
        #expect(rig.viewModel.activeProfile?.userName == "demo")
    }

    @Test("Forgetting the active profile is a sign-out")
    func forgetActiveIsSignOut() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        rig.store.session = first
        await rig.viewModel.restoreSession()

        await rig.viewModel.forgetProfile(first.id)

        #expect(rig.client(forToken: "token-1").signOutCallCount == 1)
        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.store.profiles().isEmpty)
        #expect(rig.session.connectionID == nil)
    }

    @Test("Signing out of the last profile shows the form with nothing saved")
    func signOutOfLastProfile() async {
        let rig = await signedInRig()

        await rig.viewModel.disconnect()

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.viewModel.profiles.isEmpty)
        #expect(rig.viewModel.activeProfile == nil)
    }

    @Test("A revoked token forgets that profile but keeps the others listed")
    func revokedTokenKeepsOtherProfiles() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        rig.store.session = first
        rig.store.session = second
        rig.client(forToken: "token-2").fetchCurrentUserResult = .failure(APIError.unauthorized)

        await rig.viewModel.restoreSession()

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.viewModel.errorMessage != nil)
        #expect(rig.viewModel.profiles == [first])
        #expect(rig.viewModel.activeProfile == nil)
        #expect(rig.viewModel.otherProfiles == [first])
    }

    @Test("Profiles saved on a previous launch are listed before any restore")
    func profilesLoadAtInit() {
        let store = InMemorySessionStore()
        let first = profile(serverA, user: "user-1", token: "token-1")
        store.session = first

        let viewModel = ServerConnectionViewModel(sessionStore: store) { _, _ in MockJellyfinClient() }

        #expect(viewModel.profiles == [first])
        #expect(viewModel.activeProfileID == first.id)
    }

    // MARK: - Overlapping changes

    /// Two profiles saved, the second active and restored
    private func twoProfileRig(cache: MediaCacheStore? = nil) async -> (Rig, first: SavedSession, second: SavedSession) {
        let rig = Rig(cache: cache)
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        rig.store.session = first
        rig.store.session = second
        await rig.viewModel.restoreSession()
        return (rig, first, second)
    }

    @Test("Sign Out and Switch are ignored while a sign-out waits on the server")
    func overlappingSignOutIsIgnored() async {
        let (rig, first, _) = await twoProfileRig()
        let gate = AsyncGate()
        rig.client(forToken: "token-2").signOutDelay = { await gate.waitIgnoringCancellation() }

        let signOut = Task { await rig.viewModel.disconnect() }
        await gate.arrivals(atLeast: 1)
        #expect(rig.viewModel.isChangingProfile)
        await rig.viewModel.disconnect()
        await rig.viewModel.switchToProfile(first.id)
        await gate.open()
        await signOut.value

        // Only the profile signed out of is gone; the other is now active
        #expect(rig.store.profiles().map(\.id) == [first.id])
        #expect(rig.viewModel.activeProfileID == first.id)
        #expect(rig.client(forToken: "token-2").signOutCallCount == 1)
        #expect(rig.client(forToken: "token-1").signOutCallCount == 0)
        #expect(rig.viewModel.state == .connected)
        #expect(!rig.viewModel.isChangingProfile)
    }

    @Test("A forgotten profile leaves the list before its server is asked to sign it out")
    func forgetRemovesBeforeNetwork() async {
        let (rig, first, second) = await twoProfileRig()
        let gate = AsyncGate()
        rig.client(forToken: "token-1").signOutDelay = { await gate.waitIgnoringCancellation() }

        let forget = Task { await rig.viewModel.forgetProfile(first.id) }
        await gate.arrivals(atLeast: 1)
        #expect(rig.store.profiles().map(\.id) == [second.id])
        #expect(rig.viewModel.profiles.map(\.id) == [second.id])
        await gate.open()
        await forget.value

        #expect(rig.client(forToken: "token-1").signOutCallCount == 1)
        #expect(rig.viewModel.state == .connected)
    }

    @Test("Forgetting a profile from the sign-in form removes it without signing in as another")
    func forgetFromFormDoesNotSwitch() async {
        let rig = Rig()
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        rig.store.session = first
        rig.store.session = second
        rig.client(forToken: "token-2").fetchCurrentUserResult = .failure(APIError.networkError("offline"))
        await rig.viewModel.restoreSession()
        #expect(rig.viewModel.state == .disconnected)

        await rig.viewModel.forgetProfile(second.id)

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.session.connectionID == nil)
        #expect(rig.store.profiles() == [first])
        // Its session still ends on the server, though the app never connected
        #expect(rig.client(forToken: "token-2").signOutCallCount == 1)
    }

    @Test("Backing out of Add Profile mid-sign-in ends the new token and keeps the current session")
    func cancelledAddProfile() async throws {
        let rig = await signedInRig()
        let current = try #require(rig.session.client as? MockJellyfinClient)
        let gate = AsyncGate()
        let second = signInClient(user: "user-2", token: "token-2")
        second.librariesDelay = { try? await gate.wait() }
        rig.queuedSignIns = [second]

        let add = Task { await rig.viewModel.addProfile() }
        await gate.arrivals(atLeast: 1)
        add.cancel()
        let added = await add.value

        #expect(!added)
        #expect(second.signOutCallCount == 1)
        #expect(rig.session.client as? MockJellyfinClient === current)
        #expect(rig.store.profiles().map(\.userID) == ["user-1"])
        #expect(rig.viewModel.errorMessage == nil)
        #expect(!rig.viewModel.isChangingProfile)
    }

    @Test("Add Profile with no session left signs in like the form does")
    func addProfileWithoutSessionSignsIn() async {
        let rig = Rig()
        rig.queuedSignIns = [signInClient(user: "user-1", token: "token-1")]
        rig.viewModel.serverURL = serverA.absoluteString

        let added = await rig.viewModel.addProfile()

        #expect(added)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.store.profiles().map(\.userID) == ["user-1"])
    }

    // MARK: - Caches

    private func seed(_ cache: MediaCacheStore, _ profile: SavedSession) async {
        let scope = CacheScope(serverURL: profile.serverURL, userID: profile.userID)
        await cache.write([Library(id: "lib-\(profile.userID)", name: "Movies", collectionType: .movies)], scope: scope, key: .libraries)
        await cache.write(User(id: profile.userID, name: profile.userID), scope: scope, key: .currentUser)
    }

    private func cachedLibraries(_ cache: MediaCacheStore, _ profile: SavedSession) async -> [Library]? {
        await cache.read([Library].self, scope: CacheScope(serverURL: profile.serverURL, userID: profile.userID), key: .libraries)
    }

    @Test("Switching keeps the profile left behind cached, and forgetting it purges only its cache")
    func cachesFollowProfiles() async {
        let cache = MediaCacheStore.makeInMemory()
        let first = profile(serverA, user: "user-1", token: "token-1")
        let second = profile(serverB, user: "user-2", token: "token-2")
        await seed(cache, first)
        await seed(cache, second)
        let (rig, _, _) = await twoProfileRig(cache: cache)
        #expect(rig.viewModel.state == .connected)

        await rig.viewModel.switchToProfile(first.id)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.viewModel.activeProfileID == first.id)
        #expect(await cachedLibraries(cache, second) != nil)

        await rig.viewModel.forgetProfile(second.id)
        #expect(await cachedLibraries(cache, second) == nil)
        #expect(await cachedLibraries(cache, first) != nil)
    }
}

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

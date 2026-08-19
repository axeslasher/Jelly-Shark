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
    /// been validated yet, so the session starts disconnected and only becomes
    /// connected once background validation authenticates that same client.
    @Test("A client authenticated after publication connects on refresh")
    func connectsAfterDeferredValidation() {
        let session = AppSession()
        let client = MockJellyfinClient()
        session.setClient(client)
        #expect(session.isConnected == false)

        client.currentUser = User(id: "u1", name: "Test")
        session.refreshConnectionState()
        #expect(session.isConnected)
    }

    /// The regression guard for the skeleton hang: the deferred flip has to be
    /// visible to Observation. When `isConnected` was computed through the
    /// client — a plain class Observation cannot see into — no reader was
    /// invalidated, so every `.task(id: session.isConnected)` in the app
    /// missed the transition and its screen never started loading.
    @Test("The deferred flip notifies Observation")
    func deferredFlipIsObservable() {
        let session = AppSession()
        let client = MockJellyfinClient()
        session.setClient(client)

        final class ChangeFlag: @unchecked Sendable {
            var didChange = false
        }
        let flag = ChangeFlag()
        withObservationTracking {
            _ = session.isConnected
        } onChange: {
            flag.didChange = true
        }

        client.currentUser = User(id: "u1", name: "Test")
        session.refreshConnectionState()

        #expect(flag.didChange)
    }
}

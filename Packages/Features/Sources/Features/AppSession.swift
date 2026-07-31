import Foundation
import JellyfinKit
import Observation

/// Shared session state for the app
///
/// Holds the active Jellyfin client after a successful server connection
/// so any feature (browsing, playback, etc.) can access it via the
/// SwiftUI environment.
@Observable
@MainActor
public final class AppSession {
    /// The active, authenticated Jellyfin client, if connected
    public private(set) var client: (any JellyfinClientProtocol)?

    /// The metadata cache bound to the connected user's scope, published
    /// alongside the client so view models hydrate from — and never across —
    /// the signed-in profile. Nil when the composition root runs cache-less
    /// (previews, tests).
    public private(set) var scopedCache: ScopedCache?

    /// The shared authority for watched/favorite/progress display state
    /// (#193). Owned here so every screen resolves through one overlay;
    /// activated per connection, cleared with it.
    public let userState = UserStateStore()

    /// Whether there is an authenticated connection to a server
    public var isConnected: Bool {
        client?.isAuthenticated ?? false
    }

    public init() {}

    /// Store the client (and its cache scope) after a successful connection
    public func setClient(_ client: any JellyfinClientProtocol, scopedCache: ScopedCache? = nil) {
        self.client = client
        self.scopedCache = scopedCache
        if let scopedCache {
            let userState = userState
            Task {
                await userState.activate(cache: scopedCache)
            }
        }
    }

    /// Clear the client on disconnect. Also drops all resolved user state —
    /// the same privacy boundary as the cache scope purge.
    public func clearClient() {
        client = nil
        scopedCache = nil
        userState.deactivate()
    }
}

/// A `task(id:)` key that changes when the session does, as well as when the
/// content does.
///
/// A detail page keyed on content alone survives a sign-out: the id it watches
/// is the item's, which does not change when the session ends or when a
/// different account signs in, so the task never reruns and the previous
/// account's page — including its watched and favourite state — stays on
/// screen. Two Jellyfin users on one server do not necessarily see the same
/// libraries.
///
/// On tvOS this is unreachable today, because `RootView` pops a tab's
/// navigation stack when you switch away from it, so no detail page is still
/// pushed by the time you reach Settings to sign out. That popping is a
/// workaround for a `sidebarAdaptable` pop-settle stall, `#if os(tvOS)`-guarded
/// — so visionOS, which keeps each tab's stack, has no such protection. Scope
/// the key to the session rather than relying on a navigation workaround to
/// double as a privacy boundary.
struct SessionScopedID<ContentID: Hashable>: Equatable {
    let content: ContentID
    let isConnected: Bool
}

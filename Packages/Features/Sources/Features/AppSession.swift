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

    /// Whether there is an authenticated connection to a server
    public var isConnected: Bool {
        client?.isAuthenticated ?? false
    }

    public init() {}

    /// Store the client after a successful connection
    public func setClient(_ client: any JellyfinClientProtocol) {
        self.client = client
    }

    /// Clear the client on disconnect
    public func clearClient() {
        client = nil
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

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

    /// The genre cards' remembered backdrops (#207). Owned here so the picks
    /// live and die with the signed-in profile's cache scope, exactly like
    /// `userState`. Internal on purpose: only `Features` renders genre cards.
    let genreBackdrops = GenreBackdropStore()

    /// Whether there is an authenticated connection to a server
    ///
    /// Stored, not computed through `client.isAuthenticated`: `JellyfinClient`
    /// is a plain class, so nothing it does is visible to Observation. The
    /// instant-connect path publishes a client whose token has not been
    /// validated yet (`isAuthenticated` is false until `fetchCurrentUser()`
    /// returns), so the flip to true happened inside that non-observable
    /// object and no reader was ever invalidated — every
    /// `.task(id: session.isConnected)` in the app missed the transition and
    /// its screen sat on the skeleton. Kept in step by `setClient`,
    /// `clearClient`, and `refreshConnectionState`.
    public private(set) var isConnected = false

    public init() {}

    /// The in-flight overlay activation, retained so a sign-out (or a
    /// replacement connection) can cancel it — an unretained task could
    /// complete after `deactivate()` and repopulate state across the
    /// privacy boundary
    private var activationTask: Task<Void, Never>?

    /// Store the client (and its cache scope) after a successful connection
    public func setClient(_ client: any JellyfinClientProtocol, scopedCache: ScopedCache? = nil) {
        self.client = client
        self.scopedCache = scopedCache
        isConnected = client.isAuthenticated
        activationTask?.cancel()
        activationTask = nil
        if let scopedCache {
            let userState = userState
            let genreBackdrops = genreBackdrops
            // One task for both, so a single `cancel()` covers them. Serial
            // because both reads land on the same cache actor anyway; user
            // state goes first because watched badges are content, while the
            // genre picks are decoration.
            activationTask = Task {
                await userState.activate(cache: scopedCache)
                // Cancellation is cooperative: without this, a sign-out
                // landing while the first read is in flight would still go on
                // to bind the second store to the scope just purged.
                guard !Task.isCancelled else { return }
                await genreBackdrops.activate(cache: scopedCache)
            }
        }
    }

    /// Re-read the client's authentication state after something outside this
    /// object changed it — specifically the background token validation on the
    /// instant-connect path, which authenticates a client that was already
    /// published. Without this call that transition is invisible to readers.
    public func refreshConnectionState() {
        isConnected = client?.isAuthenticated ?? false
    }

    /// Clear the client on disconnect. Also drops all resolved user state and
    /// every remembered genre backdrop — the same privacy boundary as the
    /// cache scope purge.
    public func clearClient() {
        activationTask?.cancel()
        activationTask = nil
        client = nil
        scopedCache = nil
        isConnected = false
        userState.deactivate()
        genreBackdrops.deactivate()
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

import Foundation
import Observation

/// Why a page owes a refresh. Ordered so a drain can take the deepest
/// pending reason and satisfy the shallower ones for free.
public enum RefreshReason: Int, Comparable, Sendable {
    /// Resume, Next Up, watch dates, container counts.
    case watchState
    /// The above, plus Recently Added and the genre shelves.
    case libraries
    /// The above, plus the affinity seam (#86). Nothing posts this yet.
    case deep

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Collects the reasons a page's content has gone stale, and holds the
/// in-flight playback sessions a refresh must wait behind.
///
/// #237 asked "has enough time passed since I last refreshed?" and
/// refetched on arrival. That answered a question nobody asked: a tab
/// switch changes nothing, while finishing a movie changes everything the
/// moment it ends. This inverts it — producers post, the page drains — and
/// keeps a floor only for the case no producer can see, a change made on
/// another client.
@MainActor
@Observable
public final class ContentRefreshCoordinator {
    /// Identifies one playback session between presentation and teardown.
    public struct PlaybackTicket: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// How long an idle return goes without re-checking the server.
    /// A feel value — bisect on device, never against the simulator.
    public static let floor: Duration = .seconds(30)

    /// How long to wait between checks for a registered-but-still-playing
    /// session. Not a timeout: the loop ends when the session reports or
    /// the wait is cancelled.
    private static let sessionPollInterval: Duration = .milliseconds(50)

    /// Changes on every post, so a view keyed on it re-runs its drain even
    /// while already on screen. A set alone cannot do this: posting a
    /// reason already present would not change the key.
    public private(set) var revision = 0

    /// Pending reasons, each stamped with the revision at which it was
    /// posted. The stamp is what lets `completeInitialLoad` retire only
    /// the reasons that load actually covered — a plain set forces an
    /// all-or-nothing choice, and "some of these are covered" is the
    /// normal case (#236 § 8).
    private var pending: [RefreshReason: Int] = [:]

    /// Whether the page's own first load has settled. A drain must not
    /// start before it: the drain's `.libraries` tier calls `forceReload`
    /// and would supersede the very load it is waiting on (#236 § 8.1).
    public var isInitialLoadSettled = false
    private var lastRefresh: Date?

    /// Sessions registered at presentation, before any dismissal can run.
    /// Registering at teardown instead would make the refresh depend on
    /// SwiftUI's ordering between `onDisappear` and a presenter's
    /// `onDismiss`, which is not guaranteed — and that ordering bet is the
    /// race this type exists to remove (#236 § 6). A nil value means
    /// "playing"; a task means "reporting".
    private var sessions: [PlaybackTicket: Task<Void, Never>?] = [:]

    public var hasPlaybackInFlight: Bool {
        !sessions.isEmpty
    }

    public init() {}

    // MARK: - Producers

    public func post(_ reason: RefreshReason) {
        revision &+= 1
        pending[reason] = revision
    }

    // MARK: - Playback ordering

    /// Call when a player is presented, not when it tears down.
    public func registerPlayback() -> PlaybackTicket {
        let ticket = PlaybackTicket(id: UUID())
        sessions[ticket] = Task<Void, Never>?.none
        return ticket
    }

    /// Call from the player's teardown with the task that reports the
    /// final position.
    public func finishPlayback(_ ticket: PlaybackTicket, stop: Task<Void, Never>) {
        guard sessions.index(forKey: ticket) != nil else { return }
        sessions[ticket] = stop
        post(.watchState)
    }

    /// Wait until every session registered *at the time each check runs*
    /// has reported.
    ///
    /// Cancellation returns immediately and leaves the sessions
    /// registered, so the next drain waits for them properly. Swallowing
    /// it and looping would spin this actor — `Task.sleep` throws without
    /// suspending once cancelled — and block the very teardown that
    /// supplies the stop task.
    public func awaitPlaybackReporting() async {
        while !sessions.isEmpty {
            let snapshot = sessions.compactMapValues { $0 }
            guard snapshot.count == sessions.count else {
                do {
                    try await Task.sleep(for: Self.sessionPollInterval)
                } catch {
                    return
                }
                continue
            }
            for task in snapshot.values {
                await task.value
            }
            // Only the tickets we actually awaited. A player opened while
            // we were suspended is still live, and forgetting it would let
            // the next drain race its stopped report.
            for ticket in snapshot.keys {
                sessions[ticket] = nil
            }
            return
        }
    }

    // MARK: - Draining

    /// The reason to refresh right now, or nil for "do nothing". Removes
    /// what it returns; `finishDrain` decides whether it stays removed.
    public func takeReasons(now: Date) -> RefreshReason? {
        if let deepest = pending.keys.max() {
            pending.removeAll()
            return deepest
        }
        // Nothing has refreshed yet, so the page's own initial load is the
        // refresh. Returning a reason here made cold launch fan out twice.
        guard let lastRefresh else { return nil }
        guard now.timeIntervalSince(lastRefresh) >= Self.floor.timeIntervalValue else {
            return nil
        }
        return .watchState
    }

    /// Close a drain. A failure re-posts its reason and leaves the floor
    /// unstarted, so a dropped network cannot mark the page fresh.
    public func finishDrain(deepest: RefreshReason, succeeded: Bool, now: Date) {
        if succeeded {
            lastRefresh = now
        } else {
            pending[deepest] = revision
        }
    }

    /// One open drain. Held by the page for the length of its refresh so a
    /// second cannot start and a cancelled one can put its reason back.
    public struct DrainToken: Sendable {
        fileprivate let id: UUID
        public let reason: RefreshReason
    }

    /// How a drain ended. `cancelled` is neither of the other two: it must
    /// not start the floor (nothing was confirmed) and it must put the
    /// reason back (the work is still owed).
    public enum DrainOutcome: Sendable {
        case succeeded
        case failed
        case cancelled
    }

    private var activeDrain: UUID?

    /// Claim the next refresh, or nil for "nothing owed, or one is already
    /// running".
    public func beginDrain(now: Date) -> DrainToken? {
        guard activeDrain == nil, let reason = takeReasons(now: now) else { return nil }
        let token = DrainToken(id: UUID(), reason: reason)
        activeDrain = token.id
        return token
    }

    /// Close a drain. A stale token is ignored, so a superseded page
    /// cannot stamp the floor for work a newer drain is still doing.
    ///
    /// Only `.cancelled` bumps the revision before restoring its reason.
    /// `.failed` restores the reason without bumping: the page keys its
    /// drain task on the revision, so bumping on failure would re-run the
    /// drain immediately — an unbounded retry loop against a dead server.
    /// A reason restored on failure stays owed until the next arrival or
    /// post wakes a drain for it.
    public func endDrain(_ token: DrainToken, outcome: DrainOutcome, now: Date) {
        guard activeDrain == token.id else { return }
        activeDrain = nil
        switch outcome {
        case .succeeded:
            lastRefresh = now
        case .cancelled:
            revision &+= 1
            pending[token.reason] = revision
        case .failed:
            pending[token.reason] = revision
        }
    }

    /// The page's own first load stands in for a refresh.
    ///
    /// - Parameter revisionAtStart: the revision read immediately before the
    ///   load began. Reasons raised before that point are covered by the load
    ///   and are cleared; anything posted while it ran is not, and survives.
    public func completeInitialLoad(revisionAtStart: Int, succeeded: Bool, now: Date) {
        guard succeeded else { return }
        lastRefresh = now
        // Retire only what the load covered. Clearing everything drops a
        // reason posted mid-load; clearing nothing repeats the full load that
        // just finished. Both happen at once routinely — library discovery
        // posts `.libraries` before the load, and playback can end during it.
        pending = pending.filter { $0.value > revisionAtStart }
    }
}

extension Duration {
    /// `Duration` has no `TimeInterval` bridge; components are
    /// (seconds, attoseconds).
    var timeIntervalValue: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}

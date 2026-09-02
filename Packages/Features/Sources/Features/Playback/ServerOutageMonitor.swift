import Foundation
import JellyfinKit

/// Why a playing session is currently cut off from its server, as the
/// reporting layer sees it (#188).
///
/// A *condition* of a `.playing` session, not a lifecycle state: nothing
/// about what is mounted changes while one is up. AVKit keeps retrying
/// underneath — both measured outages (85 s under `docker pause`, 4 m 47 s
/// under `docker stop`) healed on their own from the stall point — so the
/// app's job is to say what is happening and how to leave, never to time
/// the session out.
public enum ServerOutage: Equatable, Sendable {
    /// The server answers, but with a 503: Jellyfin is booting. Playback
    /// resumes on its own once it is up.
    case starting

    /// The server answered with some other 5xx.
    case serverError(statusCode: Int)

    /// Nothing answers. A request that timed out (a frozen server) and a
    /// connection that was refused (a stopped one) both land here: the
    /// transport layer collapses `URLError` to a description string, the
    /// two are indistinguishable to a viewer, and both recover the same
    /// way. The raw description still reaches the device log through the
    /// `[report] progress FAILED` line.
    case unreachable

    /// Classify one failed progress report.
    static func classify(_ error: any Error) -> ServerOutage {
        switch error {
        case APIError.serverError(statusCode: 503):
            .starting
        case let APIError.serverError(statusCode):
            .serverError(statusCode: statusCode)
        default:
            .unreachable
        }
    }
}

/// The detector behind the reconnecting affordance: one sample per
/// progress-report attempt, and a verdict that is pure in its inputs.
///
/// The signal is the one the issue's traces showed the app already had and
/// discarded: consecutive `reportPlaybackProgress` failures *and* a playhead
/// that has not moved since the previous sample. Either alone is not an
/// outage — reports fail for a whole buffer's worth of playback before the
/// picture freezes, and a frozen playhead is exactly what a paused viewer
/// asked for — so both are required, and the transport must not be paused.
///
/// The playhead must be the engine's periodic-time-observer mirror, never a
/// live `currentTime()`: that is a synchronous XPC call to mediaserverd,
/// measured blocking the main actor for 13 s during exactly the wedge this
/// detects (issue #188, third comment).
struct ServerOutageMonitor {
    /// What one report attempt came back with.
    enum ReportOutcome {
        case ok
        case failed(any Error)
    }

    /// How many consecutive failures it takes before a frozen playhead
    /// counts. One failed report is a dropped request; two on a frozen
    /// playhead is a dead session. Injectable so a test can pin the
    /// boundary without editing a constant.
    let stallFailureThreshold: Int

    /// The least time between two samples that both count.
    ///
    /// Samples arrive out of band as well as on the heartbeat — every
    /// transport event, an in-place audio switch, a native-picker reconcile
    /// — so two can land inside one tick of the playhead mirror and read as
    /// "frozen" over moving video: a pause and a resume three seconds apart
    /// during an outage with a full buffer would raise the banner over a
    /// playing picture. A sample closer than this to the last one that
    /// counted is ignored outright: no counter, no playhead, no change of
    /// verdict.
    let minimumSampleSpacing: Duration

    /// The clock the spacing is measured on; injectable so a test can
    /// place samples exactly.
    private let now: () -> ContinuousClock.Instant

    private(set) var consecutiveFailures = 0

    /// Samples folded in since the last `reset()`, whatever their outcome.
    /// Test support: how a test tells "the report landed" from "the verdict
    /// is in", and "ignored by the spacing" from "counted".
    private(set) var sampleCount = 0

    /// The verdict after the latest sample; nil while healthy.
    private(set) var outage: ServerOutage?

    /// The previous counted sample's playhead, so this one can be compared
    /// against it. Nil before the first sample and after `reset()`.
    private var lastPlayhead: Double?

    /// When the previous counted sample landed.
    private var lastSampleAt: ContinuousClock.Instant?

    init(
        stallFailureThreshold: Int = 2,
        minimumSampleSpacing: Duration = .seconds(5),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
    ) {
        self.stallFailureThreshold = stallFailureThreshold
        self.minimumSampleSpacing = minimumSampleSpacing
        self.now = now
    }

    /// Fold one report attempt in and return the verdict.
    ///
    /// - Parameters:
    ///   - outcome: whether the report landed
    ///   - playhead: the engine's mirrored playhead, nil when the engine
    ///     has none yet — which never counts as frozen, since there is no
    ///     evidence either way
    ///   - transportStatus: a paused transport exempts the sample entirely
    ///     — the viewer asked for the frozen playhead, and a report that
    ///     fails while they wait says nothing about the session they will
    ///     resume into
    @discardableResult
    mutating func record(
        _ outcome: ReportOutcome,
        playhead: Double?,
        transportStatus: PlaybackTransportStatus,
    ) -> ServerOutage? {
        let instant = now()
        if let lastSampleAt, instant - lastSampleAt < minimumSampleSpacing {
            return outage
        }
        lastSampleAt = instant
        defer { lastPlayhead = playhead }
        sampleCount += 1

        switch outcome {
        case .ok:
            // The first report that lands ends the outage outright, and the
            // count with it (the body's first recovery signal)
            consecutiveFailures = 0
            outage = nil

        case let .failed(error):
            guard transportStatus != .paused else {
                outage = nil
                break
            }
            consecutiveFailures += 1
            // A playhead that moved since the last sample is the body's
            // second recovery signal — media is flowing whatever telemetry
            // says. The failure count is deliberately kept: a session that
            // freezes again on the next failed sample is still the same
            // outage and must not wait for the threshold a second time.
            let frozen = playhead != nil && playhead == lastPlayhead
            let stalled = consecutiveFailures >= stallFailureThreshold && frozen
            // Re-classified on every failing sample, so a server that comes
            // back as 503 while booting updates a banner that started as
            // "unreachable"
            outage = stalled ? ServerOutage.classify(error) : nil
        }

        return outage
    }

    /// Forget the session: run when the reporting loop it samples stops
    /// (stop, rebuild), so the next session starts with no history.
    mutating func reset() {
        consecutiveFailures = 0
        sampleCount = 0
        outage = nil
        lastPlayhead = nil
        lastSampleAt = nil
    }
}

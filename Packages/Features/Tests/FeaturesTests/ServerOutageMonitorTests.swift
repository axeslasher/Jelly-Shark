@testable import Features
import JellyfinKit
import Testing

/// The pure decision behind the reconnecting affordance (#188): given a
/// run of progress-report outcomes and the playhead mirror at each, decide
/// whether the session is cut off from its server. The observation around
/// it — the heartbeat, the periodic time observer — needs a real player and
/// a real server; this covers the verdict, which is where a false positive
/// (a banner over a healthy rebuffer) or a false negative (a frozen frame
/// with nothing said) would come from.
@Suite("Server outage monitor")
struct ServerOutageMonitorTests {
    private let refused = APIError.networkError("Could not connect to the server.")
    private let timedOut = APIError.networkError("The request timed out.")
    private let booting = APIError.serverError(statusCode: 503)

    /// A clock the test moves by hand, so sample spacing is exact rather
    /// than whatever the runner's scheduling happens to produce
    private final class ManualClock {
        private let base = ContinuousClock.now
        var elapsed: Duration = .zero

        func now() -> ContinuousClock.Instant {
            base + elapsed
        }
    }

    /// A monitor on a manual clock. Every `record` lands ten seconds after
    /// the last by default — one heartbeat apart — so the spacing rule is
    /// out of the way unless a test is about it.
    private struct Harness {
        let clock: ManualClock
        var monitor: ServerOutageMonitor

        init(stallFailureThreshold: Int = 2) {
            let clock = ManualClock()
            self.clock = clock
            monitor = ServerOutageMonitor(stallFailureThreshold: stallFailureThreshold, now: clock.now)
        }

        @discardableResult
        mutating func record(
            _ outcome: ServerOutageMonitor.ReportOutcome,
            playhead: Double?,
            transportStatus: PlaybackTransportStatus,
            after: Duration = .seconds(10),
        ) -> ServerOutage? {
            clock.elapsed += after
            return monitor.record(outcome, playhead: playhead, transportStatus: transportStatus)
        }
    }

    // MARK: - Entering

    @Test("One failed report on a frozen playhead is a dropped request, not an outage")
    func singleFailureIsNotAnOutage() {
        var h = Harness()
        h.record(.ok, playhead: 30, transportStatus: .playing)

        let verdict = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
        #expect(h.monitor.consecutiveFailures == 1)
    }

    @Test("Consecutive failures a heartbeat apart on a frozen playhead are an outage")
    func consecutiveFailuresOnFrozenPlayheadIsAnOutage() {
        // The `docker stop` trace: the playhead sits at one value while
        // every report comes back connection-refused
        var h = Harness()
        h.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)

        let verdict = h.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay, after: .seconds(10))

        #expect(verdict == .unreachable)
        #expect(h.monitor.outage == .unreachable)
    }

    @Test("Failures while the playhead still advances are a draining buffer, not an outage")
    func failuresWithAdvancingPlayheadAreNotAnOutage() {
        // The `docker pause` trace between 18:06 and 18:08: reports failing
        // for two minutes while 150 s of buffer plays out. A banner there
        // would be wrong — the picture is moving.
        var h = Harness()
        var verdict: ServerOutage?
        for playhead in [48.6, 118.8, 156.3] {
            verdict = h.record(.failed(timedOut), playhead: playhead, transportStatus: .playing)
        }

        #expect(verdict == nil)
        #expect(h.monitor.consecutiveFailures == 3)
    }

    @Test("The first frozen sample after the buffer drains raises the outage")
    func freezeAfterDrainRaisesTheOutage() {
        // The same trace one heartbeat on: 18:09:34, playhead unchanged
        var h = Harness()
        for playhead in [48.6, 118.8, 156.3] {
            h.record(.failed(timedOut), playhead: playhead, transportStatus: .playing)
        }

        let verdict = h.record(.failed(timedOut), playhead: 156.3, transportStatus: .waitingToPlay)

        #expect(verdict == .unreachable)
    }

    @Test("A paused viewer's failures neither accrue nor show")
    func pausedIsExempt() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .paused)

        let verdict = h.record(.failed(refused), playhead: 30, transportStatus: .paused)

        #expect(verdict == nil)
        #expect(h.monitor.consecutiveFailures == 0)
        #expect(h.monitor.sampleCount == 2)
    }

    @Test("After a resume, the next spaced failed sample on a frozen playhead raises the outage")
    func resumeAfterPauseRaisesTheOutage() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        // Paused: counted as a sample, accrues nothing, shows nothing
        let paused = h.record(.failed(refused), playhead: 30, transportStatus: .paused)

        let resumed = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(paused == nil)
        #expect(resumed == .unreachable)
        #expect(h.monitor.consecutiveFailures == 2)
    }

    @Test("A playhead the engine has not reported yet never counts as frozen")
    func missingPlayheadIsNotFrozen() {
        var h = Harness()
        h.record(.failed(refused), playhead: nil, transportStatus: .waitingToPlay)

        let verdict = h.record(.failed(refused), playhead: nil, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
    }

    @Test("The threshold is the boundary: one below stays healthy, at it raises")
    func thresholdIsTheBoundary() {
        var h = Harness(stallFailureThreshold: 3)
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        let below = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        let at = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(below == nil)
        #expect(at == .unreachable)
    }

    // MARK: - Sample spacing

    @Test("Two failures inside the spacing never raise: the second is not a sample")
    func samplesInsideTheSpacingNeverRaise() {
        // A pause-then-resume a second apart during an outage: two transport
        // events, two reports, one mirror tick — the playhead reads
        // "frozen" over video that is playing
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        let verdict = h.record(.failed(refused), playhead: 30, transportStatus: .playing, after: .seconds(1))

        #expect(verdict == nil)
        #expect(h.monitor.consecutiveFailures == 1)
        #expect(h.monitor.sampleCount == 1)
    }

    @Test("Two failures a heartbeat apart on a frozen playhead raise")
    func spacedFailuresRaise() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        let verdict = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay, after: .seconds(10))

        #expect(verdict == .unreachable)
        #expect(h.monitor.sampleCount == 2)
    }

    @Test("A sample inside the spacing touches nothing and answers with the standing verdict")
    func sampleInsideTheSpacingIsIgnored() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        // An ok that lands a second later would reset the count if it
        // counted; it must not, and it must not move the playhead baseline
        let ignored = h.record(.ok, playhead: 31, transportStatus: .playing, after: .seconds(1))
        #expect(ignored == nil)
        #expect(h.monitor.consecutiveFailures == 1)
        #expect(h.monitor.sampleCount == 1)

        let raised = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay, after: .seconds(10))
        #expect(raised == .unreachable)

        // With the outage standing, an ignored sample still answers with it
        let standing = h.record(.ok, playhead: 30, transportStatus: .waitingToPlay, after: .seconds(1))
        #expect(standing == .unreachable)
        #expect(h.monitor.outage == .unreachable)
    }

    // MARK: - Leaving

    @Test("The first report that lands ends the outage and the count")
    func successEndsTheOutage() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        let verdict = h.record(.ok, playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
        #expect(h.monitor.consecutiveFailures == 0)
    }

    @Test("A playhead that moves ends the outage even while reports still fail")
    func movementEndsTheOutage() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        let verdict = h.record(.failed(refused), playhead: 41, transportStatus: .playing)

        #expect(verdict == nil)
    }

    @Test("A session that freezes again re-enters without waiting for the threshold twice")
    func refreezeReentersImmediately() {
        // A seek during the outage moves the mirror once; the very next
        // frozen sample is the same outage, not a fresh one
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        h.record(.failed(refused), playhead: 41, transportStatus: .waitingToPlay)

        let verdict = h.record(.failed(refused), playhead: 41, transportStatus: .waitingToPlay)

        #expect(verdict == .unreachable)
    }

    @Test("reset() forgets the session")
    func resetForgetsTheSession() {
        var h = Harness()
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        h.monitor.reset()
        let verdict = h.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
        #expect(h.monitor.consecutiveFailures == 1)
        #expect(h.monitor.sampleCount == 1)
    }

    // MARK: - Classification

    @Test("A 503 is the server booting; other 5xx carry their code; everything else is unreachable")
    func classification() {
        #expect(ServerOutage.classify(booting) == .starting)
        #expect(ServerOutage.classify(APIError.serverError(statusCode: 502)) == .serverError(statusCode: 502))
        #expect(ServerOutage.classify(refused) == .unreachable)
        #expect(ServerOutage.classify(timedOut) == .unreachable)
        #expect(ServerOutage.classify(APIError.generic("boom")) == .unreachable)
        #expect(ServerOutage.classify(CancellationError()) == .unreachable)
    }

    @Test("The verdict follows the server as it comes back: unreachable, then booting")
    func classificationFollowsTheServer() {
        // The `docker start` trace: refused while down, 503 while Jellyfin
        // boots, then ok
        var h = Harness()
        h.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)
        let down = h.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)
        let up = h.record(.failed(booting), playhead: 124.2, transportStatus: .waitingToPlay)
        let ready = h.record(.ok, playhead: 124.2, transportStatus: .waitingToPlay)

        #expect(down == .unreachable)
        #expect(up == .starting)
        #expect(ready == nil)
    }

    // MARK: - Copy

    @Test("Every state names the exit and leads with a distinct title")
    func copyNamesTheExit() {
        let states: [ServerOutage] = [.unreachable, .starting, .serverError(statusCode: 500)]

        for state in states {
            #expect(state.detail.hasSuffix(ServerOutage.exitInstruction))
        }
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(ServerOutage.serverError(statusCode: 502).title.contains("502"))
    }
}

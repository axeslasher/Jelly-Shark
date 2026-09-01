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

    // MARK: - Entering

    @Test("One failed report on a frozen playhead is a dropped request, not an outage")
    func singleFailureIsNotAnOutage() {
        var monitor = ServerOutageMonitor()
        monitor.record(.ok, playhead: 30, transportStatus: .playing)

        let verdict = monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
        #expect(monitor.consecutiveFailures == 1)
    }

    @Test("Consecutive failures on a frozen playhead are an outage")
    func consecutiveFailuresOnFrozenPlayheadIsAnOutage() {
        // The `docker stop` trace: the playhead sits at one value while
        // every report comes back connection-refused
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)

        let verdict = monitor.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)

        #expect(verdict == .unreachable)
        #expect(monitor.outage == .unreachable)
    }

    @Test("Failures while the playhead still advances are a draining buffer, not an outage")
    func failuresWithAdvancingPlayheadAreNotAnOutage() {
        // The `docker pause` trace between 18:06 and 18:08: reports failing
        // for two minutes while 150 s of buffer plays out. A banner there
        // would be wrong — the picture is moving.
        var monitor = ServerOutageMonitor()
        var verdict: ServerOutage?
        for playhead in [48.6, 118.8, 156.3] {
            verdict = monitor.record(.failed(timedOut), playhead: playhead, transportStatus: .playing)
        }

        #expect(verdict == nil)
        #expect(monitor.consecutiveFailures == 3)
    }

    @Test("The first frozen sample after the buffer drains raises the outage")
    func freezeAfterDrainRaisesTheOutage() {
        // The same trace one heartbeat on: 18:09:34, playhead unchanged
        var monitor = ServerOutageMonitor()
        for playhead in [48.6, 118.8, 156.3] {
            monitor.record(.failed(timedOut), playhead: playhead, transportStatus: .playing)
        }

        let verdict = monitor.record(.failed(timedOut), playhead: 156.3, transportStatus: .waitingToPlay)

        #expect(verdict == .unreachable)
    }

    @Test("A paused viewer's frozen playhead is not an outage")
    func pausedIsExempt() {
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 30, transportStatus: .paused)

        let verdict = monitor.record(.failed(refused), playhead: 30, transportStatus: .paused)

        #expect(verdict == nil)
        #expect(monitor.consecutiveFailures == 2)
    }

    @Test("Resuming with the server still dead raises the outage on the next sample")
    func resumeAfterPauseRaisesTheOutage() {
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 30, transportStatus: .paused)
        monitor.record(.failed(refused), playhead: 30, transportStatus: .paused)

        let verdict = monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == .unreachable)
    }

    @Test("A playhead the engine has not reported yet never counts as frozen")
    func missingPlayheadIsNotFrozen() {
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: nil, transportStatus: .waitingToPlay)

        let verdict = monitor.record(.failed(refused), playhead: nil, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
    }

    @Test("The threshold is the boundary: one below stays healthy, at it raises")
    func thresholdIsTheBoundary() {
        var monitor = ServerOutageMonitor(stallFailureThreshold: 3)
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        let below = monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        let at = monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(below == nil)
        #expect(at == .unreachable)
    }

    // MARK: - Leaving

    @Test("The first report that lands ends the outage and the count")
    func successEndsTheOutage() {
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        let verdict = monitor.record(.ok, playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
        #expect(monitor.consecutiveFailures == 0)
    }

    @Test("A playhead that moves ends the outage even while reports still fail")
    func movementEndsTheOutage() {
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        let verdict = monitor.record(.failed(refused), playhead: 41, transportStatus: .playing)

        #expect(verdict == nil)
    }

    @Test("A session that freezes again re-enters without waiting for the threshold twice")
    func refreezeReentersImmediately() {
        // A seek during the outage moves the mirror once; the very next
        // frozen sample is the same outage, not a fresh one
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        monitor.record(.failed(refused), playhead: 41, transportStatus: .waitingToPlay)

        let verdict = monitor.record(.failed(refused), playhead: 41, transportStatus: .waitingToPlay)

        #expect(verdict == .unreachable)
    }

    @Test("reset() forgets the session")
    func resetForgetsTheSession() {
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)
        monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        monitor.reset()
        let verdict = monitor.record(.failed(refused), playhead: 30, transportStatus: .waitingToPlay)

        #expect(verdict == nil)
        #expect(monitor.consecutiveFailures == 1)
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
        var monitor = ServerOutageMonitor()
        monitor.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)
        let down = monitor.record(.failed(refused), playhead: 124.2, transportStatus: .waitingToPlay)
        let up = monitor.record(.failed(booting), playhead: 124.2, transportStatus: .waitingToPlay)
        let ready = monitor.record(.ok, playhead: 124.2, transportStatus: .waitingToPlay)

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

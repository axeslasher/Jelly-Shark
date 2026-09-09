@testable import Features
import Foundation
import Testing

@Suite("ContentRefreshCoordinator")
@MainActor
struct ContentRefreshCoordinatorTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Revision

    @Test func postingBumpsTheRevisionSoADrainKeyChanges() {
        let coordinator = ContentRefreshCoordinator()
        let before = coordinator.revision
        coordinator.post(.watchState)
        #expect(coordinator.revision > before)
    }

    @Test func postingTheSameReasonTwiceStillWakesADrain() {
        // The set dedupes; the revision must not. A second finished
        // episode is a second thing to reconcile.
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.watchState)
        let after = coordinator.revision
        coordinator.post(.watchState)
        #expect(coordinator.revision > after)
    }

    // MARK: - Taking reasons

    @Test func takeReturnsTheDeepestPendingReason() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.watchState)
        coordinator.post(.libraries)
        #expect(coordinator.takeReasons(now: epoch) == .libraries)
    }

    @Test func takeReturnsNilBeforeAnyRefreshHasHappened() {
        // Cold start: the page's own initial load is the refresh. Handing
        // back `.watchState` here made launch fan out a second time,
        // 400ms after the first load settled.
        let coordinator = ContentRefreshCoordinator()
        #expect(coordinator.takeReasons(now: epoch) == nil)
    }

    @Test func takeReturnsNilInsideTheFloorWithNothingPending() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.finishDrain(deepest: .watchState, succeeded: true, now: epoch)
        // Zero requests is the point: an idle tab return must not fetch.
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(5)) == nil)
    }

    @Test func takeReturnsWatchStateOnceTheFloorExpires() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.finishDrain(deepest: .watchState, succeeded: true, now: epoch)
        // Shallow on purpose — a silent re-check must not rebuild the
        // hero and restart the marquee under an idle viewer.
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(3600)) == .watchState)
    }

    @Test func aPendingReasonBeatsTheFloor() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.finishDrain(deepest: .watchState, succeeded: true, now: epoch)
        coordinator.post(.libraries)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .libraries)
    }

    // MARK: - Failure and concurrency

    @Test func aFailedDrainRestoresItsReasonAndDoesNotStartTheFloor() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.libraries)
        #expect(coordinator.takeReasons(now: epoch) == .libraries)
        coordinator.finishDrain(deepest: .libraries, succeeded: false, now: epoch)
        // Re-posted, floor never started — otherwise a dropped network
        // marks Home fresh for 30 seconds.
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .libraries)
    }

    @Test func aSucceededDrainClearsTheSet() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.libraries)
        _ = coordinator.takeReasons(now: epoch)
        coordinator.finishDrain(deepest: .libraries, succeeded: true, now: epoch)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == nil)
    }

    @Test func aReasonPostedDuringADrainSurvivesThatDrain() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.watchState)
        _ = coordinator.takeReasons(now: epoch)
        // Something finished while the shallow refresh was in flight.
        coordinator.post(.libraries)
        coordinator.finishDrain(deepest: .watchState, succeeded: true, now: epoch)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .libraries)
    }

    // MARK: - Playback ordering (§ 6)

    @Test func finishingPlaybackPostsAWatchStateReason() {
        let coordinator = ContentRefreshCoordinator()
        let ticket = coordinator.registerPlayback()
        let before = coordinator.revision
        coordinator.finishPlayback(ticket, stop: Task {})
        // Teardown itself is the signal — the page must not wait for the
        // stop task to actually run before it knows a refresh is owed.
        #expect(coordinator.revision > before)
        #expect(coordinator.takeReasons(now: epoch) == .watchState)
    }

    @Test func finishingAnUnknownTicketRegistersNothing() {
        let coordinator = ContentRefreshCoordinator()
        let other = ContentRefreshCoordinator()
        let foreignTicket = other.registerPlayback()
        let before = coordinator.revision
        // A ticket this coordinator never issued must be a no-op, not a
        // phantom session that blocks every future drain.
        coordinator.finishPlayback(foreignTicket, stop: Task {})
        #expect(coordinator.hasPlaybackInFlight == false)
        #expect(coordinator.revision == before)
    }

    @Test func awaitingReportingReturnsImmediatelyWithNoSessions() async {
        let coordinator = ContentRefreshCoordinator()
        await coordinator.awaitPlaybackReporting()
    }

    @Test func awaitingReportingWaitsForARegisteredSessionsStopTask() async {
        let coordinator = ContentRefreshCoordinator()
        let ticket = coordinator.registerPlayback()
        let gate = AsyncGate()
        var reported = false
        coordinator.finishPlayback(ticket, stop: Task {
            try? await gate.wait()
            reported = true
        })

        let waiter = Task { await coordinator.awaitPlaybackReporting() }
        await gate.open()
        await waiter.value
        // The refresh must never read server state before the stopped
        // report lands — that is the resume race.
        #expect(reported)
    }

    @Test func cancellingTheWaitReturnsAndKeepsTheSessionRegistered() async {
        let coordinator = ContentRefreshCoordinator()
        _ = coordinator.registerPlayback() // still playing: no stop task yet

        // The drain task is keyed on the revision, so any post cancels it
        // mid-wait. Swallowing the cancellation and looping would spin the
        // main actor and block the very teardown that supplies the stop
        // task.
        let waiter = Task { await coordinator.awaitPlaybackReporting() }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await waiter.value // must return promptly, not hang

        #expect(coordinator.hasPlaybackInFlight)
    }

    @Test func awaitingDoesNotDiscardASessionRegisteredWhileItWaits() async {
        let coordinator = ContentRefreshCoordinator()
        let first = coordinator.registerPlayback()
        let gate = AsyncGate()
        coordinator.finishPlayback(first, stop: Task { try? await gate.wait() })

        let waiter = Task { await coordinator.awaitPlaybackReporting() }
        try? await Task.sleep(for: .milliseconds(10))
        // A second player opened while the first was still reporting.
        _ = coordinator.registerPlayback()
        await gate.open()
        await waiter.value

        // Clearing everything here would forget a live session, and the
        // next drain would race its stopped report.
        #expect(coordinator.hasPlaybackInFlight)
    }

    // MARK: - Drain transaction (§ 8)

    @Test func onlyOneDrainRunsAtATime() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.libraries)
        #expect(coordinator.beginDrain(now: epoch) != nil)
        // A second drain while the first is open would fan out twice for one
        // reason and race its own writes.
        #expect(coordinator.beginDrain(now: epoch) == nil)
    }

    @Test func aCancelledDrainRestoresItsReason() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.libraries)
        guard let token = coordinator.beginDrain(now: epoch) else {
            Issue.record("expected a drain")
            return
        }
        coordinator.endDrain(token, outcome: .cancelled, now: epoch)
        // Cancelled is not success: the reason is still owed, and the floor
        // must not have started.
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .libraries)
    }

    @Test func aStaleTokenCannotCloseANewerDrain() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.watchState)
        guard let first = coordinator.beginDrain(now: epoch) else { return }
        coordinator.endDrain(first, outcome: .cancelled, now: epoch)
        guard let second = coordinator.beginDrain(now: epoch) else { return }
        coordinator.endDrain(first, outcome: .succeeded, now: epoch)
        // The stale `.succeeded` call must not have released the serial
        // guard: `activeDrain` still belongs to `second`, so no drain comes
        // back even well past the floor.
        #expect(coordinator.beginDrain(now: epoch.addingTimeInterval(40)) == nil)
        // The stale token must not stamp the floor for work the second drain
        // is still doing.
        coordinator.endDrain(second, outcome: .failed, now: epoch)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .watchState)
    }

    @Test func completingTheInitialLoadSatisfiesReasonsRaisedBeforeIt() {
        let coordinator = ContentRefreshCoordinator()
        // Library discovery posts before the first load finishes; that load
        // already covers it.
        coordinator.post(.libraries)
        let revision = coordinator.revision
        coordinator.completeInitialLoad(revisionAtStart: revision, succeeded: true, now: epoch)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == nil)
    }

    @Test func completingTheInitialLoadRetiresOnlyThePreLoadReason() {
        let coordinator = ContentRefreshCoordinator()
        // The realistic shape, and the one two separate tests miss: library
        // discovery posts before the load, playback ends during it.
        coordinator.post(.libraries)
        let revision = coordinator.revision
        coordinator.post(.watchState)
        coordinator.completeInitialLoad(revisionAtStart: revision, succeeded: true, now: epoch)
        // `.libraries` was covered; repeating it redoes the fan-out that just
        // finished.
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .watchState)
    }

    @Test func aCancelledDrainWakesTheNextOne() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.libraries)
        guard let token = coordinator.beginDrain(now: epoch) else {
            Issue.record("expected a drain")
            return
        }
        let before = coordinator.revision
        // Restoring a reason without a revision bump leaves it owed with
        // nothing scheduled to drain it.
        coordinator.endDrain(token, outcome: .cancelled, now: epoch)
        #expect(coordinator.revision > before)
    }

    @Test func aFailedDrainRestoresItsReasonWithoutWakingADrain() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.libraries)
        guard let token = coordinator.beginDrain(now: epoch) else {
            Issue.record("expected a drain")
            return
        }
        let before = coordinator.revision
        // Failure restores the reason but must not bump the revision: the
        // page keys its drain task on the revision, so bumping here would
        // re-run the drain immediately — an unbounded retry loop against a
        // dead server.
        coordinator.endDrain(token, outcome: .failed, now: epoch)
        #expect(coordinator.revision == before)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .libraries)
    }

    @Test func completingTheInitialLoadKeepsReasonsRaisedDuringIt() {
        let coordinator = ContentRefreshCoordinator()
        let revision = coordinator.revision
        // Something finished playing while the first load was in flight.
        coordinator.post(.watchState)
        coordinator.completeInitialLoad(revisionAtStart: revision, succeeded: true, now: epoch)
        #expect(coordinator.takeReasons(now: epoch.addingTimeInterval(1)) == .watchState)
    }

    @Test func aSucceededDrainStartsTheFloorAndReleasesTheGuard() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.watchState)
        guard let token = coordinator.beginDrain(now: epoch) else {
            Issue.record("expected a drain")
            return
        }
        coordinator.endDrain(token, outcome: .succeeded, now: epoch)
        // Inside the floor, with nothing pending: no drain.
        #expect(coordinator.beginDrain(now: epoch.addingTimeInterval(5)) == nil)

        coordinator.post(.libraries)
        // The serial guard was released, and a pending reason beats the floor.
        guard let second = coordinator.beginDrain(now: epoch.addingTimeInterval(6)) else {
            Issue.record("expected a drain")
            return
        }
        #expect(second.reason == .libraries)
        coordinator.endDrain(second, outcome: .succeeded, now: epoch.addingTimeInterval(6))

        // Floor expiry, long after either drain.
        #expect(coordinator.beginDrain(now: epoch.addingTimeInterval(3600))?.reason == .watchState)
    }

    @Test func aDeeperReasonPostedDuringADrainSurvivesACancellation() {
        let coordinator = ContentRefreshCoordinator()
        coordinator.post(.watchState)
        guard let token = coordinator.beginDrain(now: epoch) else {
            Issue.record("expected a drain")
            return
        }
        // Something else finished while the shallow drain was still open.
        coordinator.post(.libraries)
        // A second drain must not start while one is already open, even
        // though a deeper reason has since arrived.
        #expect(coordinator.beginDrain(now: epoch) == nil)
        coordinator.endDrain(token, outcome: .cancelled, now: epoch)
        // Both the restored `.watchState` and the surviving `.libraries` are
        // owed; the deeper one wins.
        #expect(coordinator.beginDrain(now: epoch)?.reason == .libraries)
    }
}

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
}

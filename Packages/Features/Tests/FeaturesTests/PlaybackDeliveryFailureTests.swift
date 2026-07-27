import AVFoundation
@testable import Features
import Testing

/// The pure decision behind the first-frame watchdog (#151): given what the
/// player looks like when the deadline elapses, decide whether delivery
/// failed. The observation and teardown around it need a real AVPlayer and a
/// real server, which no suite in this repo can provide — this covers the
/// classification, which is where the false positives would come from.
@MainActor
@Suite("Playback delivery failure")
struct PlaybackDeliveryFailureTests {
    // MARK: - Not failures

    @Test("A playing player at the deadline is not a failure")
    func playingIsHealthy() {
        let verdict = PlaybackViewModel.firstFrameVerdict(
            timeControlStatus: .playing,
            positionAdvanced: false,
            errorDescription: nil,
            progress: .init(),
            previousProgress: .init(),
        )

        #expect(verdict == .noFailure)
    }

    @Test("A playhead that has advanced is not a failure, whatever the rate")
    func advancedPositionIsHealthy() {
        // A transcode that started slowly and is buffering again by the
        // deadline: frames demonstrably arrived, so this must never fail
        let verdict = PlaybackViewModel.firstFrameVerdict(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            positionAdvanced: true,
            errorDescription: nil,
            progress: .init(),
            previousProgress: .init(),
        )

        #expect(verdict == .noFailure)
    }

    @Test("A viewer who paused before the first frame is not a failure")
    func pausedIsHealthy() {
        let verdict = PlaybackViewModel.firstFrameVerdict(
            timeControlStatus: .paused,
            positionAdvanced: false,
            errorDescription: nil,
            progress: .init(),
            previousProgress: .init(),
        )

        #expect(verdict == .noFailure)
    }

    // MARK: - Slow, not broken

    @Test("A buffer that grew between deadlines earns another one")
    func growingBufferKeepsWaiting() {
        // The false positive that motivated this parameter: under tvOS's
        // network conditioner a file that direct-played fine on a healthy
        // link raised an error screen, because the playhead is the only other
        // progress signal and it does not move while the buffer fills.
        let verdict = PlaybackViewModel.firstFrameVerdict(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            positionAdvanced: false,
            errorDescription: nil,
            progress: .init(bufferedSeconds: 4.5, bytesTransferred: 900_000),
            previousProgress: .init(bufferedSeconds: 1.2, bytesTransferred: 200_000),
        )

        #expect(verdict == .keepWaiting)
    }

    @Test("Bytes arriving with no loaded ranges yet still earns another deadline")
    func growingBytesKeepsWaiting() {
        // The direct-play case the buffer measure alone missed. A
        // progressively-downloaded file reports no loaded ranges until
        // AVPlayer has read enough of the container to know its duration, so
        // `bufferedSeconds` sits at zero while the socket is busy. A throttled
        // conditioner run failed on exactly this shape — bytes climbing, no
        // ranges, playhead still.
        let verdict = PlaybackViewModel.firstFrameVerdict(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            positionAdvanced: false,
            errorDescription: nil,
            progress: .init(bufferedSeconds: 0, bytesTransferred: 250_000),
            previousProgress: .init(bufferedSeconds: 0, bytesTransferred: 40000),
        )

        #expect(verdict == .keepWaiting)
    }

    @Test("Progress that stopped moving is a failure, however much it holds")
    func stalledDeliveryFails() {
        // Media arrived once and then stopped. Waiting further would restore
        // the indefinite hang this whole mechanism replaces, so progress that
        // has not moved since the last deadline fails no matter how much it
        // already carries.
        for buffered in [0.0, 2.0, 30.0] {
            let verdict = PlaybackViewModel.firstFrameVerdict(
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                positionAdvanced: false,
                errorDescription: nil,
                progress: .init(bufferedSeconds: buffered, bytesTransferred: 1000),
                previousProgress: .init(bufferedSeconds: buffered, bytesTransferred: 1000),
            )

            #expect(verdict == .failed(PlaybackViewModel.firstFrameTimeoutMessage))
        }
    }

    // MARK: - Failures

    @Test("Still waiting with nothing delivered is a failure")
    func waitingWithNothingDeliveredFails() {
        let verdict = PlaybackViewModel.firstFrameVerdict(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            positionAdvanced: false,
            errorDescription: nil,
            progress: .init(),
            previousProgress: .init(),
        )

        #expect(verdict == .failed(PlaybackViewModel.firstFrameTimeoutMessage))
    }

    @Test("A failed player item beats every other signal")
    func itemErrorAlwaysFails() {
        // AVPlayer drops the rate to zero when an item fails, so the paused
        // exemption above must not swallow a genuine error — and neither must
        // a buffer that is still filling.
        for status in [
            AVPlayer.TimeControlStatus.paused,
            .waitingToPlayAtSpecifiedRate,
            .playing,
        ] {
            let verdict = PlaybackViewModel.firstFrameVerdict(
                timeControlStatus: status,
                positionAdvanced: true,
                errorDescription: "The operation could not be completed",
                progress: .init(bufferedSeconds: 9, bytesTransferred: 5000),
                previousProgress: .init(bufferedSeconds: 1, bytesTransferred: 100),
            )

            #expect(
                verdict == .failed(
                    PlaybackViewModel.deliveryFailureMessage(
                        reason: "The operation could not be completed",
                    ),
                ),
            )
        }
    }

    // MARK: - Messages

    @Test("The timeout message names no duration")
    func timeoutMessageNamesNoDuration() {
        // The deadline re-arms itself while the buffer grows, so the wait can
        // be far longer than `firstFrameTimeout`. Any figure in this string
        // would be a lie by the time a viewer read it.
        let seconds = PlaybackViewModel.firstFrameTimeout.components.seconds

        #expect(!PlaybackViewModel.firstFrameTimeoutMessage.contains("\(seconds)"))
    }

    @Test("A reported reason is appended to the advice, not swapped for it")
    func reasonIsAppendedToAdvice() {
        let bare = PlaybackViewModel.deliveryFailureMessage(reason: nil)
        let detailed = PlaybackViewModel.deliveryFailureMessage(reason: "Cannot Open")

        #expect(detailed.hasPrefix(bare))
        #expect(detailed.hasSuffix("Cannot Open"))
    }

    @Test("An empty reason falls back to the bare advice")
    func emptyReasonFallsBack() {
        #expect(
            PlaybackViewModel.deliveryFailureMessage(reason: "")
                == PlaybackViewModel.deliveryFailureMessage(reason: nil),
        )
    }
}

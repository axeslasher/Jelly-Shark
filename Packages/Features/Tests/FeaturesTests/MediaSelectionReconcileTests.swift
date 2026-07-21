@testable import Features
import JellyfinKit
import Testing

/// The pure decision matrix behind native-picker reconciliation (#89):
/// given what AVKit has selected and what the view model believes, decide
/// whether stored state follows, stays, or logs a miss.
@MainActor
@Suite("Media selection reconciliation")
struct MediaSelectionReconcileTests {
    private func subtitleStream(index: Int, title: String, language: String) -> MediaStreamInfo {
        MediaStreamInfo(
            index: index,
            type: .subtitle,
            displayTitle: title,
            language: language,
            codec: "subrip",
            isTextSubtitleStream: true,
        )
    }

    private func audioStream(index: Int, title: String, language: String) -> MediaStreamInfo {
        MediaStreamInfo(
            index: index,
            type: .audio,
            displayTitle: title,
            language: language,
            codec: "aac",
        )
    }

    private var subtitleStreams: [MediaStreamInfo] {
        [
            subtitleStream(index: 2, title: "English - SUBRIP", language: "eng"),
            subtitleStream(index: 3, title: "Spanish - SUBRIP", language: "spa"),
        ]
    }

    private var options: [LegibleOption] {
        [
            LegibleOption(position: 0, displayName: "English - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Spanish - SUBRIP", languageTag: "es"),
        ]
    }

    // MARK: - Subtitles

    @Test("A native subtitle switch updates the stored index")
    func subtitleSwitch() {
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: 1,
            currentIndex: 2,
            sessionUsesBurnIn: false,
            streams: subtitleStreams,
            options: options,
        )
        #expect(decision == .update(3))
    }

    @Test("A native deselect maps to subtitles off")
    func subtitleOff() {
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: nil,
            currentIndex: 2,
            sessionUsesBurnIn: false,
            streams: subtitleStreams,
            options: options,
        )
        #expect(decision == .update(nil))
    }

    @Test("The echo of the app's own selection is a no-op")
    func subtitleEcho() {
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: 0,
            currentIndex: 2,
            sessionUsesBurnIn: false,
            streams: subtitleStreams,
            options: options,
        )
        #expect(decision == .noChange)
    }

    @Test("An echo survives a reverse-ambiguous single-rendition master")
    func subtitleEchoAmbiguous() {
        // One advertised rendition: every stream forward-matches it via the
        // sole-option fallback, so the reverse match alone can't decide.
        // The stored stream explains the selection, so nothing changes.
        let soleOption = [
            LegibleOption(position: 0, displayName: "Nameless", languageTag: nil),
        ]
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: 0,
            currentIndex: 2,
            sessionUsesBurnIn: false,
            streams: subtitleStreams,
            options: soleOption,
        )
        #expect(decision == .noChange)
    }

    @Test("An unexplained ambiguous selection reports unmatched")
    func subtitleAmbiguousUnmatched() {
        let soleOption = [
            LegibleOption(position: 0, displayName: "Nameless", languageTag: nil),
        ]
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: 0,
            currentIndex: nil,
            sessionUsesBurnIn: false,
            streams: subtitleStreams,
            options: soleOption,
        )
        #expect(decision == .unmatched)
    }

    @Test("Burn-in sessions never reconcile subtitles")
    func subtitleBurnIn() {
        // A burned-in track has a selected index but no legible selection;
        // adopting nil would falsely report subtitles off
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: nil,
            currentIndex: 4,
            sessionUsesBurnIn: true,
            streams: subtitleStreams,
            options: options,
        )
        #expect(decision == .noChange)
    }

    @Test("Off matching off is a no-op")
    func subtitleOffAlreadyOff() {
        let decision = PlaybackViewModel.subtitleReconcileDecision(
            selectedPosition: nil,
            currentIndex: nil,
            sessionUsesBurnIn: false,
            streams: subtitleStreams,
            options: options,
        )
        #expect(decision == .noChange)
    }

    // MARK: - Audio

    @Test("A native audio switch updates the stored index")
    func audioSwitch() {
        let options = [
            AudibleOption(position: 0, displayName: "English", languageTag: "en"),
            AudibleOption(position: 1, displayName: "日本語", languageTag: "ja"),
        ]
        let decision = PlaybackViewModel.audioReconcileDecision(
            selectedOption: options[1],
            currentIndex: 1,
            streams: [
                audioStream(index: 1, title: "English - AAC - Stereo", language: "eng"),
                audioStream(index: 2, title: "Japanese - AAC - Stereo", language: "jpn"),
            ],
            options: options,
        )
        #expect(decision == .update(2))
    }

    @Test("A same-language variant switch resolves positionally")
    func audioSwitchPositional() {
        let options = [
            AudibleOption(position: 0, displayName: "Mono - English", languageTag: "en"),
            AudibleOption(position: 1, displayName: "Stereo - English", languageTag: "en"),
            AudibleOption(position: 2, displayName: "Surround 5.1 - English", languageTag: "en"),
        ]
        let decision = PlaybackViewModel.audioReconcileDecision(
            selectedOption: options[2],
            currentIndex: 1,
            streams: [
                audioStream(index: 1, title: "Mono", language: "eng"),
                audioStream(index: 2, title: "Stereo", language: "eng"),
                audioStream(index: 3, title: "Surround 5.1", language: "eng"),
            ],
            options: options,
        )
        #expect(decision == .update(3))
    }

    @Test("An audio selection matching current state is a no-op")
    func audioEcho() {
        let options = [
            AudibleOption(position: 0, displayName: "English - AAC - Stereo", languageTag: "en"),
        ]
        let decision = PlaybackViewModel.audioReconcileDecision(
            selectedOption: options[0],
            currentIndex: 1,
            streams: [
                audioStream(index: 1, title: "English - AAC - Stereo", language: "eng"),
            ],
            options: options,
        )
        #expect(decision == .noChange)
    }

    @Test("A nil audio selection is a loading transient, not intent")
    func audioNilSelection() {
        let decision = PlaybackViewModel.audioReconcileDecision(
            selectedOption: nil,
            currentIndex: 1,
            streams: [
                audioStream(index: 1, title: "English - AAC - Stereo", language: "eng"),
            ],
            options: [],
        )
        #expect(decision == .noChange)
    }

    @Test("An unmatchable audio selection reports unmatched")
    func audioUnmatched() {
        // Count mismatch blocks the positional tier, nothing else matches
        let options = [
            AudibleOption(position: 0, displayName: "Track 1", languageTag: nil),
        ]
        let decision = PlaybackViewModel.audioReconcileDecision(
            selectedOption: options[0],
            currentIndex: 1,
            streams: [
                audioStream(index: 1, title: "English - AAC - Stereo", language: "eng"),
                audioStream(index: 2, title: "English - AC3 - 5.1", language: "eng"),
            ],
            options: options,
        )
        #expect(decision == .unmatched)
    }
}

@testable import Features
import JellyfinKit
import Testing

@Suite("AudioOptionMatcher")
struct AudioOptionMatcherTests {
    private func stream(
        index: Int,
        displayTitle: String? = nil,
        language: String? = nil,
    ) -> MediaStreamInfo {
        MediaStreamInfo(
            index: index,
            type: .audio,
            displayTitle: displayTitle,
            language: language,
            codec: "aac",
        )
    }

    @Test("Exact display-name match wins")
    func displayNameMatch() {
        let streams = [
            stream(index: 1, displayTitle: "English - AAC - Stereo", language: "eng"),
            stream(index: 2, displayTitle: "English - AC3 - 5.1", language: "eng"),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "English - AAC - Stereo", languageTag: "en"),
            AudibleOption(position: 1, displayName: "English - AC3 - 5.1", languageTag: "en"),
        ]

        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[1], streams: streams, options: options,
        ) == 2)
    }

    @Test("Unambiguous language match bridges ISO-639-2 and BCP-47")
    func languageMatch() {
        let streams = [
            stream(index: 1, displayTitle: "English - AAC - Stereo", language: "eng"),
            stream(index: 2, displayTitle: "Japanese - AAC - Stereo", language: "jpn"),
        ]
        // An embedded track's name rarely matches Jellyfin's DisplayTitle
        let options = [
            AudibleOption(position: 0, displayName: "English", languageTag: "en"),
            AudibleOption(position: 1, displayName: "日本語", languageTag: "ja"),
        ]

        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[1], streams: streams, options: options,
        ) == 2)
    }

    @Test("Same-language variants fall back to positional correlation")
    func positionalMatch() {
        // The Creepshow 2 shape: every track is English, AVFoundation's
        // names don't equal Jellyfin's titles, and only the ordinal can
        // tell mono/stereo/5.1 apart
        let streams = [
            stream(index: 1, displayTitle: "Mono - English - AAC", language: "eng"),
            stream(index: 2, displayTitle: "Stereo - English - AAC", language: "eng"),
            stream(index: 3, displayTitle: "Surround 5.1 - English - AC3", language: "eng"),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "Mono - English", languageTag: "en"),
            AudibleOption(position: 1, displayName: "Stereo - English", languageTag: "en"),
            AudibleOption(position: 2, displayName: "Surround 5.1 - English", languageTag: "en"),
        ]

        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[1], streams: streams, options: options,
        ) == 2)
        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[2], streams: streams, options: options,
        ) == 3)
    }

    @Test("Positional correlation requires matching counts")
    func positionalCountMismatch() {
        let streams = [
            stream(index: 1, displayTitle: "English - Stereo", language: "eng"),
            stream(index: 2, displayTitle: "English - 5.1", language: "eng"),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "Stereo", languageTag: "en"),
        ]

        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[0], streams: streams, options: options,
        ) == nil)
    }

    @Test("A language conflict at the position vetoes the ordinal")
    func positionalLanguageConflict() {
        // The selected option declares Japanese but its positional
        // candidate is English (and the language tier can't resolve it —
        // no Japanese stream exists): refuse rather than misreport
        let streams = [
            stream(index: 1, displayTitle: "English A", language: "eng"),
            stream(index: 2, displayTitle: "English B", language: "eng"),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "何か", languageTag: "ja"),
            AudibleOption(position: 1, displayName: "Something", languageTag: "en"),
        ]

        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[0], streams: streams, options: options,
        ) == nil)
    }

    @Test("An untagged option positionally matches an untagged stream list")
    func positionalUntagged() {
        let streams = [
            stream(index: 1, displayTitle: nil, language: nil),
            stream(index: 2, displayTitle: nil, language: nil),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "Track 1", languageTag: nil),
            AudibleOption(position: 1, displayName: "Track 2", languageTag: nil),
        ]

        #expect(AudioOptionMatcher.streamIndex(
            forSelectedOption: options[1], streams: streams, options: options,
        ) == 2)
    }

    // MARK: - Forward direction (#187)

    @Test("Forward match lands on the option whose reverse match is the stream")
    func forwardPositionalMatch() {
        // The same shape as positionalMatch, driven the other way: the app
        // menu picked a Jellyfin index and needs the option to select
        let streams = [
            stream(index: 1, displayTitle: "Mono - English - AAC", language: "eng"),
            stream(index: 2, displayTitle: "Stereo - English - AAC", language: "eng"),
            stream(index: 3, displayTitle: "Surround 5.1 - English - AC3", language: "eng"),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "Mono - English", languageTag: "en"),
            AudibleOption(position: 1, displayName: "Stereo - English", languageTag: "en"),
            AudibleOption(position: 2, displayName: "Surround 5.1 - English", languageTag: "en"),
        ]

        #expect(AudioOptionMatcher.position(
            forTargetStream: streams[1], streams: streams, options: options,
        ) == 1)
        #expect(AudioOptionMatcher.position(
            forTargetStream: streams[2], streams: streams, options: options,
        ) == 2)
    }

    @Test("Forward match refuses a count mismatch")
    func forwardCountMismatch() {
        let streams = [
            stream(index: 1, displayTitle: "English - Stereo", language: "eng"),
            stream(index: 2, displayTitle: "English - 5.1", language: "eng"),
            stream(index: 3, displayTitle: "English - Mono", language: "eng"),
        ]
        // AVFoundation surfaced fewer options than Jellyfin lists streams:
        // no tier can place index 2 confidently, so the caller must rebuild
        let options = [
            AudibleOption(position: 0, displayName: "Stereo", languageTag: "en"),
            AudibleOption(position: 1, displayName: "Surround", languageTag: "en"),
        ]

        #expect(AudioOptionMatcher.position(
            forTargetStream: streams[1], streams: streams, options: options,
        ) == nil)
    }

    @Test("Forward and reverse agree: a selection's echo reconciles to itself")
    func forwardReverseRoundTrip() {
        // The property the in-place path relies on (#187): selecting the
        // forward-matched option must reconcile back to the same stream
        // index, or reconciliation would rewrite the committed selection
        let streams = [
            stream(index: 1, displayTitle: "English - AAC - Stereo", language: "eng"),
            stream(index: 2, displayTitle: "日本語 - AAC - Stereo", language: "jpn"),
            stream(index: 3, displayTitle: "Commentaire - AAC", language: "fra"),
        ]
        let options = [
            AudibleOption(position: 0, displayName: "English", languageTag: "en"),
            AudibleOption(position: 1, displayName: "Japanese", languageTag: "ja"),
            AudibleOption(position: 2, displayName: "French", languageTag: "fr"),
        ]

        for target in streams {
            guard let position = AudioOptionMatcher.position(
                forTargetStream: target, streams: streams, options: options,
            ) else {
                Issue.record("no forward match for index \(target.index)")
                continue
            }
            let echoed = options.first { $0.position == position }.flatMap {
                AudioOptionMatcher.streamIndex(
                    forSelectedOption: $0, streams: streams, options: options,
                )
            }
            #expect(echoed == target.index)
        }
    }
}

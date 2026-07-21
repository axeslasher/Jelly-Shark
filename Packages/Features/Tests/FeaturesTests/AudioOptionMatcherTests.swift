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
}

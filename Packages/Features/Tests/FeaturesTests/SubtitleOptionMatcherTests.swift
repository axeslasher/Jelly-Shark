@testable import Features
import JellyfinKit
import Testing

@Suite("SubtitleOptionMatcher")
struct SubtitleOptionMatcherTests {
    private func stream(
        index: Int = 2,
        displayTitle: String? = nil,
        language: String? = nil,
    ) -> MediaStreamInfo {
        MediaStreamInfo(
            index: index,
            type: .subtitle,
            displayTitle: displayTitle,
            language: language,
            codec: "subrip",
            isTextSubtitleStream: true,
        )
    }

    @Test("Exact display-name match wins")
    func displayNameMatch() {
        let options = [
            LegibleOption(position: 0, displayName: "English - Default - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "English - Forced - SUBRIP", languageTag: "en"),
        ]
        let target = stream(displayTitle: "English - Forced - SUBRIP", language: "eng")

        #expect(SubtitleOptionMatcher.match(target, in: options) == 1)
    }

    @Test("Unambiguous language match bridges ISO-639-2 and BCP-47")
    func languageMatch() {
        let options = [
            LegibleOption(position: 0, displayName: "Track A", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Track B", languageTag: "es"),
        ]
        let target = stream(displayTitle: "Spanish - SUBRIP", language: "spa")

        #expect(SubtitleOptionMatcher.match(target, in: options) == 1)
    }

    @Test("Ambiguous language yields no match")
    func ambiguousLanguage() {
        let options = [
            LegibleOption(position: 0, displayName: "Track A", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Track B", languageTag: "en"),
        ]
        let target = stream(displayTitle: "English - SUBRIP", language: "eng")

        #expect(SubtitleOptionMatcher.match(target, in: options) == nil)
    }

    @Test("A sole option is used as a last resort")
    func singleOptionFallback() {
        let options = [
            LegibleOption(position: 0, displayName: "Whatever", languageTag: nil),
        ]
        let target = stream(displayTitle: "English - SUBRIP", language: "eng")

        #expect(SubtitleOptionMatcher.match(target, in: options) == 0)
    }

    @Test("No options yields no match")
    func emptyOptions() {
        let target = stream(displayTitle: "English - SUBRIP", language: "eng")

        #expect(SubtitleOptionMatcher.match(target, in: []) == nil)
    }

    @Test("Untagged streams don't match on language")
    func missingLanguage() {
        let options = [
            LegibleOption(position: 0, displayName: "Track A", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Track B", languageTag: "es"),
        ]
        let target = stream(displayTitle: nil, language: nil)

        #expect(SubtitleOptionMatcher.match(target, in: options) == nil)
    }

    @Test("Regional language tags match their base language")
    func regionalTagMatch() {
        let options = [
            LegibleOption(position: 0, displayName: "Português", languageTag: "pt-BR"),
            LegibleOption(position: 1, displayName: "English", languageTag: "en-US"),
        ]
        let target = stream(displayTitle: "Portuguese - SUBRIP", language: "por")

        #expect(SubtitleOptionMatcher.match(target, in: options) == 0)
    }

    // MARK: - Reverse matching (position → stream index)

    @Test("Reverse match finds the unique stream for a position")
    func reverseUniqueMatch() {
        let options = [
            LegibleOption(position: 0, displayName: "English - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Spanish - SUBRIP", languageTag: "es"),
        ]
        let streams = [
            stream(index: 2, displayTitle: "English - SUBRIP", language: "eng"),
            stream(index: 3, displayTitle: "Spanish - SUBRIP", language: "spa"),
        ]

        #expect(SubtitleOptionMatcher.streamIndex(
            forSelectedPosition: 1, streams: streams, options: options,
        ) == 3)
    }

    @Test("Reverse match is nil when several streams claim the position")
    func reverseAmbiguous() {
        // A single advertised rendition makes every stream forward-match it
        // via the sole-option fallback — reconciliation must not guess
        let options = [
            LegibleOption(position: 0, displayName: "English - SUBRIP", languageTag: "en"),
        ]
        let streams = [
            stream(index: 2, displayTitle: "Other A", language: nil),
            stream(index: 3, displayTitle: "Other B", language: nil),
        ]

        #expect(SubtitleOptionMatcher.streamIndex(
            forSelectedPosition: 0, streams: streams, options: options,
        ) == nil)
    }

    @Test("Reverse match is nil when no stream claims the position")
    func reverseNoMatch() {
        let options = [
            LegibleOption(position: 0, displayName: "English - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Spanish - SUBRIP", languageTag: "es"),
        ]
        let streams = [
            stream(index: 2, displayTitle: "German - SUBRIP", language: "ger"),
        ]

        #expect(SubtitleOptionMatcher.streamIndex(
            forSelectedPosition: 1, streams: streams, options: options,
        ) == nil)
    }
}

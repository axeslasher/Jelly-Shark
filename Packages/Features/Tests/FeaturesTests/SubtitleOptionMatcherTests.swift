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
}

import Foundation
@testable import JellyfinKit
import Testing

/// Where rung 1's audio comes from (#252). Two halves: the DEFAULT path,
/// whose behaviour is frozen at what #249 shipped and is guarded here against
/// drift, and the non-default path, which carries the committed track when
/// the stream-index mapping corroborates it and server-transcodes whenever
/// anything is in doubt.
@Suite("RemuxAudioSelection")
struct RemuxAudioSelectionTests {
    private func stream(
        _ index: Int,
        _ codec: String,
        language: String? = nil,
        isExternal: Bool = false,
    ) -> MediaStreamInfo {
        MediaStreamInfo(index: index, type: .audio, language: language, codec: codec, isExternal: isExternal)
    }

    private func track(
        _ number: Int,
        _ codecID: String,
        language: String? = nil,
        isDefault: Bool = true,
    ) -> MatroskaTrack {
        MatroskaTrack(number: number, type: .audio, codecID: codecID, isDefault: isDefault, language: language)
    }

    // MARK: - The default path, frozen

    @Test("A carriable default carries the remuxer's own pick")
    func defaultCarries() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "eac3")],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(decision.source == .carried(trackNumber: 1))
        #expect(decision.defaultPickMismatch == nil)
    }

    @Test("Committing to the default index is the same as committing to nothing")
    func selectedDefaultIsTheDefaultPath() {
        let streams = [stream(1, "eac3"), stream(2, "ac3")]
        let tracks = [track(1, "A_EAC3"), track(2, "A_AC3")]
        let implicit = RemuxAudioSelection.decide(
            selectedStreamIndex: nil, defaultStreamIndex: 1, audioStreams: streams, matroskaTracks: tracks,
        )
        let explicit = RemuxAudioSelection.decide(
            selectedStreamIndex: 1, defaultStreamIndex: 1, audioStreams: streams, matroskaTracks: tracks,
        )
        #expect(implicit == explicit)
        #expect(implicit.source == .carried(trackNumber: 1))
    }

    /// The #251 trade: a DTS default is transcoded server-side rather than
    /// swapped for the carriable AC-3 sitting next to it, because swapping
    /// would play a track the menu says is not playing.
    @Test("An uncarriable default is server-transcoded, never swapped for a carriable neighbour")
    func uncarriableDefaultTranscodes() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "dts"), stream(2, "ac3")],
            matroskaTracks: [track(1, "A_DTS"), track(2, "A_AC3")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: 1))
        // The pick skipping an uncarriable default is not a mapping
        // disagreement, so it must not raise the warning.
        #expect(decision.defaultPickMismatch == nil)
    }

    /// Preserved verbatim from #249: with no declared default index the
    /// session still transcodes, naming no stream, even though a carriable
    /// track is present.
    @Test("No declared default index transcodes with no stream named")
    func noDeclaredDefaultTranscodes() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: nil,
            audioStreams: [stream(1, "eac3")],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: nil))
    }

    @Test("A source with no audio at all declines the rung")
    func noAudioDeclines() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil, defaultStreamIndex: nil, audioStreams: [], matroskaTracks: [],
        )
        #expect(decision.source == nil)
    }

    /// Instrumentation, not behaviour: the server's default index maps to
    /// file track 1 while the file's own FlagDefault is track 2, so the two
    /// notions of "default" disagree. The decision stays exactly what it was
    /// before #252 — the file's pick — and the disagreement is only logged.
    @Test("A default pick the mapping disagrees with is logged, not acted on")
    func defaultPickMismatchIsLoggedOnly() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "aac"), stream(2, "aac")],
            matroskaTracks: [track(1, "A_AAC", isDefault: false), track(2, "A_AAC", isDefault: true)],
        )
        #expect(decision.source == .carried(trackNumber: 2))
        #expect(decision.defaultPickMismatch == 1)
    }

    // MARK: - The non-default path

    @Test("A carriable non-default selection is carried from the file")
    func nonDefaultCarries() {
        // Track numbers deliberately unequal to the stream indices: the
        // mapping is positional, not arithmetic.
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: 2,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "eac3"), stream(2, "eac3")],
            matroskaTracks: [track(2, "A_EAC3"), track(5, "A_EAC3")],
        )
        #expect(decision.source == .carried(trackNumber: 5))
    }

    @Test("An uncarriable non-default selection stays on the rung, transcoded")
    func nonDefaultTranscodes() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: 2,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "eac3"), stream(2, "dts")],
            matroskaTracks: [track(1, "A_EAC3"), track(2, "A_DTS")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: 2))
    }

    /// The remuxer carries by exact CodecID, so a qualified spelling maps
    /// (the position is corroborated) yet still cannot be stream-copied.
    @Test("A mapped track whose CodecID is not exactly carriable is transcoded")
    func qualifiedCodecIDMapsButDoesNotCarry() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: 2,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "eac3"), stream(2, "aac")],
            matroskaTracks: [track(1, "A_EAC3"), track(2, "A_AAC/MPEG4/LC")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: 2))
    }

    /// Nothing to carry and nothing the server could transcode out of the
    /// file: standing an audio session up here would only fail on its first
    /// segment, so decline the rung as this case did before #252.
    @Test("A committed selection with no embedded audio declines the rung")
    func nonDefaultWithNoEmbeddedAudioDeclines() {
        // Sidecar audio only.
        let sidecarOnly = RemuxAudioSelection.decide(
            selectedStreamIndex: 2,
            defaultStreamIndex: nil,
            audioStreams: [stream(2, "ac3", isExternal: true)],
            matroskaTracks: [],
        )
        #expect(sidecarOnly.source == nil)

        // No audio streams listed at all.
        let silent = RemuxAudioSelection.decide(
            selectedStreamIndex: 2,
            defaultStreamIndex: 1,
            audioStreams: [],
            matroskaTracks: [],
        )
        #expect(silent.source == nil)
    }

    // MARK: - Mapping declines

    @Test("Every inconclusive mapping falls back to the server transcode")
    func ambiguousMappingsTranscode() {
        func decide(
            selected: Int,
            streams: [MediaStreamInfo],
            tracks: [MatroskaTrack],
        ) -> RemuxAudioDecision {
            RemuxAudioSelection.decide(
                selectedStreamIndex: selected, defaultStreamIndex: 1, audioStreams: streams, matroskaTracks: tracks,
            )
        }

        // Counts differ: the server sees a track the file does not have (or
        // ffmpeg dropped one), so no position means anything.
        let counts = decide(
            selected: 2,
            streams: [stream(1, "eac3"), stream(2, "ac3")],
            tracks: [track(1, "A_EAC3")],
        )
        #expect(counts.source == .serverTranscoded(streamIndex: 2))
        #expect(counts.reason.contains("the server lists 2 embedded audio streams, the file has 1 track"))

        // Track numbers the carry lookup could not tell apart — a
        // TrackEntry missing its number reads as 0, and two of those would
        // let the remuxer carry a track other than the verified one.
        let duplicates = decide(
            selected: 2,
            streams: [stream(1, "eac3"), stream(2, "eac3")],
            tracks: [track(0, "A_EAC3"), track(0, "A_EAC3")],
        )
        #expect(duplicates.source == .serverTranscoded(streamIndex: 2))
        #expect(duplicates.reason.contains("track numbers are not unique"))

        // A sidecar has no TrackEntry to carry.
        let sidecar = decide(
            selected: 2,
            streams: [stream(1, "eac3"), stream(2, "ac3", isExternal: true)],
            tracks: [track(1, "A_EAC3")],
        )
        #expect(sidecar.source == .serverTranscoded(streamIndex: 2))
        #expect(sidecar.reason.contains("external"))

        // A contradiction at a position OTHER than the selected one is what
        // a shifted sequence looks like from the selected position, where
        // everything still appears to line up.
        let shifted = decide(
            selected: 3,
            streams: [stream(1, "ac3"), stream(2, "eac3"), stream(3, "eac3")],
            tracks: [track(1, "A_EAC3"), track(2, "A_EAC3"), track(3, "A_EAC3")],
        )
        #expect(shifted.source == .serverTranscoded(streamIndex: 3))
        #expect(shifted.reason.contains("codec mismatch at audio position 0"))

        // An unknown codec at the selected position cannot corroborate; only
        // positive agreement carries.
        let unknown = decide(
            selected: 2,
            streams: [stream(1, "eac3"), stream(2, "wmapro")],
            tracks: [track(1, "A_EAC3"), track(2, "A_MS/ACM")],
        )
        #expect(unknown.source == .serverTranscoded(streamIndex: 2))
        #expect(unknown.reason.contains("cannot corroborate"))

        // Same codec, different declared language: the sequence is not what
        // the server thinks it is.
        let language = decide(
            selected: 2,
            streams: [stream(1, "eac3", language: "eng"), stream(2, "eac3", language: "spa")],
            tracks: [track(1, "A_EAC3", language: "eng"), track(2, "A_EAC3", language: "fra")],
        )
        #expect(language.source == .serverTranscoded(streamIndex: 2))
        #expect(language.reason.contains("language mismatch"))

        // A committed index the server no longer lists (stale selection).
        let absent = decide(
            selected: 5,
            streams: [stream(1, "eac3"), stream(2, "eac3")],
            tracks: [track(1, "A_EAC3"), track(2, "A_EAC3")],
        )
        #expect(absent.source == .serverTranscoded(streamIndex: 5))
        #expect(absent.reason.contains("not one of the file's audio streams"))

        // Distinct diagnoses, so a device log says which rule fired. The
        // substring assertions above are what make this meaningful: a
        // refactor collapsing all seven into one sentence differing only by
        // an interpolated index would still satisfy the set count.
        let reasons = [counts, duplicates, sidecar, shifted, unknown, language, absent].map(\.reason)
        #expect(Set(reasons).count == reasons.count)
    }

    /// The two sides spell the same language differently as a matter of
    /// course — the demuxer reads Matroska's legacy `Language` element
    /// (ISO 639-2) while Jellyfin's comes from ffprobe preferring
    /// `LanguageBCP47` (639-1) — so both are canonicalized through ICU
    /// before comparison.
    @Test("Languages corroborate across spellings, and still veto real mismatches")
    func languageCorroboration() {
        func decide(stream streamLanguage: String?, track trackLanguage: String?) -> RemuxAudioSource? {
            RemuxAudioSelection.decide(
                selectedStreamIndex: 2,
                defaultStreamIndex: 1,
                audioStreams: [stream(1, "eac3"), stream(2, "eac3", language: streamLanguage)],
                matroskaTracks: [track(1, "A_EAC3"), track(2, "A_EAC3", language: trackLanguage)],
            ).source
        }

        // The same language, spelled either way round, plus a BCP 47 tag
        // whose region is not part of the claim.
        #expect(decide(stream: "eng", track: "eng") == .carried(trackNumber: 2))
        #expect(decide(stream: "de", track: "ger") == .carried(trackNumber: 2))
        #expect(decide(stream: "spa", track: "es") == .carried(trackNumber: 2))
        #expect(decide(stream: "en-US", track: "eng") == .carried(trackNumber: 2))
        #expect(decide(stream: "ZH", track: "chi") == .carried(trackNumber: 2))

        // `und` is Matroska's "not stated", and an absent element is nil:
        // neither is a claim that can contradict.
        #expect(decide(stream: "und", track: "fre") == .carried(trackNumber: 2))
        #expect(decide(stream: nil, track: "fre") == .carried(trackNumber: 2))
        #expect(decide(stream: "eng", track: nil) == .carried(trackNumber: 2))

        // Genuinely different languages still veto the carry — including
        // the two pairs a prefix test called equal: `sl` is Slovenian and
        // `slo` is Slovak, `es` is Spanish and `est` is Estonian.
        #expect(decide(stream: "eng", track: "fre") == .serverTranscoded(streamIndex: 2))
        #expect(decide(stream: "sl", track: "slo") == .serverTranscoded(streamIndex: 2))
        #expect(decide(stream: "es", track: "est") == .serverTranscoded(streamIndex: 2))
    }

    /// These mappings are load-bearing and come from ICU, not from us: if a
    /// platform update moved any of them, real carriable selections would
    /// quietly start server-transcoding instead. Pin them.
    @Test("The ICU language canonicalization the corroboration depends on")
    func icuLanguageMappings() {
        let bibliographic = [
            ("ger", "de"), ("deu", "de"), ("fre", "fr"), ("spa", "es"), ("por", "pt"), ("jpn", "ja"),
            ("chi", "zh"), ("cze", "cs"), ("dut", "nl"), ("swe", "sv"), ("slo", "sk"), ("eng", "en"),
        ]
        for (code, canonical) in bibliographic {
            #expect(Locale.canonicalLanguageIdentifier(from: code) == canonical)
        }
        // The false-agreement vetoes depend on these landing apart.
        #expect(Locale.canonicalLanguageIdentifier(from: "sl") == "sl")
        #expect(Locale.canonicalLanguageIdentifier(from: "est") == "et")
    }

    @Test("Linear PCM corroborates as a family")
    func pcmFamily() {
        #expect(RemuxAudioSelection.codecAgreement(jellyfinCodec: "pcm_s24le", matroskaCodecID: "A_PCM/INT/LIT") == .agrees)
        #expect(RemuxAudioSelection.codecAgreement(jellyfinCodec: "pcm_s16le", matroskaCodecID: "A_AC3") == .contradicts)
        #expect(RemuxAudioSelection.codecAgreement(jellyfinCodec: "wmapro", matroskaCodecID: "A_AC3") == .unverifiable)
        #expect(RemuxAudioSelection.codecAgreement(jellyfinCodec: "ac3", matroskaCodecID: "A_MS/ACM") == .unverifiable)
    }
}

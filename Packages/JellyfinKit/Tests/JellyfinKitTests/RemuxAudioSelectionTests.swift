import Foundation
@testable import JellyfinKit
import Testing

/// Where rung 1's audio comes from (#252, #259). One rule: the session's
/// committed stream index — its selection, or the server's default when it
/// selected nothing — is carried from the file when the stream-index mapping
/// corroborates which Matroska track it is, and server-transcoded whenever
/// anything is in doubt. The file's own `FlagDefault` decides nothing (#259).
/// The shapes naming no mappable index are decided before the mapping runs,
/// each pinned below to the rung outcome it has always had.
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

    /// Real sources hand the mapping the whole `TrackEntry` list, video
    /// included; only the server's side arrives pre-filtered to audio.
    private func videoTrack(_ number: Int) -> MatroskaTrack {
        MatroskaTrack(number: number, type: .video, codecID: "V_MPEGH/ISO/HEVC")
    }

    // MARK: - The default index

    /// A smoke test, deliberately: with one stream and one track the mapped
    /// track and the file's own pick are the same track, so this pins the
    /// happy path without discriminating #259. `defaultCarriesTheMappedTrack`
    /// below is the one that does.
    @Test("A single carriable audio track is carried")
    func singleCarriableTrackIsCarried() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "eac3")],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(decision.source == .carried(trackNumber: 1))
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

    /// #259, device-reported: the file's `FlagDefault` and the server's
    /// `DefaultAudioStreamIndex` are different authorities. The server's
    /// folds in the user's persisted choice — and echoes the previous
    /// session's selection back one play later, so `selection == default` is
    /// the COMMON shape after a switch, not a rare one. Carrying the file's
    /// pick there played the French track under the English checkmark.
    @Test("The default carries the mapped track, not the file's FlagDefault")
    func defaultCarriesTheMappedTrack() {
        // The reported shape: stream 2 is the committed English track, file
        // track 2 is the French `FlagDefault`, and stream 2 maps to track 3.
        let streams = [stream(1, "eac3", language: "fra"), stream(2, "eac3", language: "eng")]
        let tracks = [
            track(2, "A_EAC3", language: "fre", isDefault: true),
            track(3, "A_EAC3", language: "eng", isDefault: false),
        ]
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil, defaultStreamIndex: 2, audioStreams: streams, matroskaTracks: tracks,
        )
        #expect(decision.source == .carried(trackNumber: 3))
        // The exact marker `docs/PLAYBACK_MATRIX.md` sends the device round
        // looking for. Its shape changed here — the old default path emitted
        // no "for stream N" suffix — so pin the text the doc quotes.
        #expect(decision.reason == "carried from the file, track 3 (A_EAC3) for stream 2")
        // And identically under the echo, which is how the session reached
        // the default path on the device in the first place. Asserted
        // absolutely rather than against `decision`: a relative check is blind
        // to anything that moves both sides together.
        let echoed = RemuxAudioSelection.decide(
            selectedStreamIndex: 2, defaultStreamIndex: 2, audioStreams: streams, matroskaTracks: tracks,
        )
        #expect(echoed.source == .carried(trackNumber: 3))
    }

    /// Also from the #257 round: a source flagging two audio tracks default.
    /// The file's pick was whichever came first, a coin toss the server's
    /// index takes no part in.
    @Test("Two default-flagged tracks follow the stream index, not the flags")
    func twoDefaultFlaggedTracks() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 2,
            audioStreams: [stream(1, "ac3"), stream(2, "ac3")],
            matroskaTracks: [track(1, "A_AC3", isDefault: true), track(2, "A_AC3", isDefault: true)],
        )
        #expect(decision.source == .carried(trackNumber: 2))
    }

    /// The case the #257 instrumentation could not even see: with the
    /// mapping inconclusive there was no mapped track to disagree with, so
    /// the old default path raised nothing and carried the remuxer's pick —
    /// track 1 — while the session claimed stream 2. Doubt now transcodes,
    /// exactly as it always has for a selection.
    @Test("An inconclusive mapping on the default index transcodes that index")
    func inconclusiveDefaultMappingTranscodes() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 2,
            audioStreams: [stream(1, "eac3"), stream(2, "eac3")],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: 2))
        #expect(decision.reason.contains("the server lists 2 embedded audio streams, the file has 1 track"))
    }

    /// A default index naming a sidecar while the file also holds embedded
    /// audio: there is no `TrackEntry` to carry, so the server transcodes the
    /// index it named rather than the remux substituting an embedded track.
    @Test("A default index external to the file transcodes rather than substituting")
    func externalDefaultTranscodes() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 2,
            audioStreams: [stream(1, "eac3"), stream(2, "ac3", isExternal: true)],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: 2))
        #expect(decision.reason.contains("external"))
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
    }

    // MARK: - Shapes naming no mappable index, whose rung outcome is unchanged

    /// #259 changed WHICH track the default carries and nothing about which
    /// rung serves the session. These three shapes name no index the mapping
    /// could resolve, so they are decided before it runs — each pinned to the
    /// outcome it had before, because declining here means descending to the
    /// copy variant and its frameskip (#99), the cost #251/#252 existed to
    /// remove.
    @Test("The shapes naming no mappable index keep the outcome they had")
    func unmappableShapesKeepTheirOutcome() {
        // A declared default the file has no embedded audio for (sidecar-only
        // audio): the server named that index and transcodes it itself, which
        // keeps the session on this rung.
        let sidecarOnlyDefault = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "ac3", isExternal: true)],
            matroskaTracks: [],
        )
        #expect(sidecarOnlyDefault.source == .serverTranscoded(streamIndex: 1))
        #expect(sidecarOnlyDefault.reason.contains("the server lists no embedded audio"))

        // No declared default and nothing carriable in the file: no index to
        // name and no track to carry, so the rung declines.
        let noDefaultNothingCarriable = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: nil,
            audioStreams: [stream(1, "dts")],
            matroskaTracks: [track(1, "A_DTS")],
        )
        #expect(noDefaultNothingCarriable.source == nil)
        #expect(noDefaultNothingCarriable.reason == "no audio in the source")

        // No declared default and no audio streams listed, but the file holds
        // a carriable track: ask the server for its own default.
        let noDefaultServerListsNothing = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: nil,
            audioStreams: [],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(noDefaultServerListsNothing.source == .serverTranscoded(streamIndex: nil))
        #expect(noDefaultServerListsNothing.reason.contains("server default"))

        // A declared default with no audio anywhere. Unchanged from #249, and
        // pinned because it is the fourth shape of this class: the server
        // transcodes an index the file cannot supply, which a refactor
        // collapsing the two identical no-embedded-audio guards would flip.
        let declaredDefaultNoAudio = RemuxAudioSelection.decide(
            selectedStreamIndex: nil, defaultStreamIndex: 1, audioStreams: [], matroskaTracks: [],
        )
        #expect(declaredDefaultNoAudio.source == .serverTranscoded(streamIndex: 1))
    }

    /// The one shape besides the inconclusive mapping that #259 moves, and it
    /// moves within rung 1: the server lists no embedded audio, its default
    /// index names a sidecar whose codec is carriable, and the file holds a
    /// carriable track. The old branch read the SIDECAR's codec, found it
    /// carriable, and carried an arbitrary embedded track under the sidecar's
    /// checkmark — the exact lie #259 exists to kill. The honest answer names
    /// the index the server resolves itself.
    @Test("An external default beside carriable file audio transcodes, never carries")
    func externalDefaultBesideCarriableFileAudio() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 1,
            audioStreams: [stream(1, "ac3", isExternal: true)],
            matroskaTracks: [track(1, "A_EAC3")],
        )
        #expect(decision.source == .serverTranscoded(streamIndex: 1))
    }

    /// The routing guard in `decide` earns its keep only here. A sidecar-only
    /// source takes a different outcome depending on whether the server has
    /// echoed the selection back as the default yet: declining before the
    /// echo, staying on this rung after. Pinned as current behaviour rather
    /// than endorsed — the asymmetry is tracked separately.
    @Test("A sidecar-only source keeps each path's outcome under the server echo")
    func sidecarOnlyUnderTheEcho() {
        let streams = [stream(1, "ac3", isExternal: true)]
        let committed = RemuxAudioSelection.decide(
            selectedStreamIndex: 1, defaultStreamIndex: nil, audioStreams: streams, matroskaTracks: [],
        )
        #expect(committed.source == nil)
        #expect(committed.reason == "the source has no embedded audio")

        let echoed = RemuxAudioSelection.decide(
            selectedStreamIndex: 1, defaultStreamIndex: 1, audioStreams: streams, matroskaTracks: [],
        )
        #expect(echoed.source == .serverTranscoded(streamIndex: 1))
        #expect(echoed.reason.contains("the server lists no embedded audio"))
    }

    /// A real file's `TrackEntry` list carries the video track too, while the
    /// server's `audioStreams` is audio-only, so the positional
    /// correspondence is between AUDIO positions — a video track occupies
    /// none. Without a fixture holding one, `mapTrackNumber`'s `.audio`
    /// filter could be deleted with every test still green while every real
    /// session quietly lost bit-exact passthrough to a count mismatch.
    @Test("A video TrackEntry occupies no audio position")
    func videoTrackDoesNotShiftTheMapping() {
        let decision = RemuxAudioSelection.decide(
            selectedStreamIndex: nil,
            defaultStreamIndex: 2,
            audioStreams: [stream(1, "eac3"), stream(2, "ac3")],
            matroskaTracks: [videoTrack(1), track(2, "A_EAC3"), track(3, "A_AC3")],
        )
        #expect(decision.source == .carried(trackNumber: 3))
    }

    /// The source has embedded audio the rung could play, but the server
    /// named no index, so there is nothing to map and nothing to name in a
    /// transcode request either. Preserved verbatim from #249.
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

    // MARK: - A non-default selection

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

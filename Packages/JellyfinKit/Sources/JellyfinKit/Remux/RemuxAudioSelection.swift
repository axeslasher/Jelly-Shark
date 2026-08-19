import Foundation

// Which audio the in-app remux (#176) plays for a given session, and where it
// comes from (#252).
//
// Rung 1 used to play the source's DEFAULT track and nothing else, so a
// session committed to any other track had to descend to the server's copy
// variant and its frameskip (#99). The external-audio path (#249) can
// server-transcode ANY stream index, so the descent is no longer necessary —
// what remains is deciding, per session, whether the committed track can be
// carried from the file (the quality bar) or must be transcoded.
//
// One stream index decides that, for every session: the committed selection,
// or `DefaultAudioStreamIndex` when the session committed to nothing. The
// server's default is the only authority on what "default" means here — it
// folds in the user's persisted choice, and was observed echoing the previous
// session's selection back one play later. The file's own `FlagDefault` is a
// property of the FILE, not of the session; the two disagree on real sources,
// and rung 1 used to carry the file's pick under the server's checkmark
// (#259).
//
// Carrying requires naming a Matroska track number, and Jellyfin names audio
// by ffprobe stream INDEX. The bridge is positional: ffmpeg creates streams in
// `TrackEntry` order and `MatroskaDemuxer.parseTracks` appends in file order,
// so the n-th non-external audio stream the server lists is the n-th audio
// `TrackEntry`. Everything else here exists to VERIFY that correspondence,
// because a wrongly carried track is the worst outcome available: the menu's
// checkmark would sit on a track that never played. Any doubt — a count
// mismatch, a codec that contradicts, a language that contradicts — falls back
// to a server-side transcode of the committed index, which the server resolves
// by index itself and cannot get wrong.

/// Where rung 1's audio comes from for one session.
public enum RemuxAudioSource: Equatable, Sendable {
    /// Stream-copied out of the source file, by Matroska track number.
    case carried(trackNumber: Int)
    /// Muxed in from a server-side audio-only transcode (#249). `nil` asks
    /// the server for its own default rather than naming a stream.
    case serverTranscoded(streamIndex: Int?)
}

/// The outcome of `RemuxAudioSelection.decide`.
public struct RemuxAudioDecision: Equatable, Sendable {
    /// `nil` when rung 1 can produce no audio at all — the caller must
    /// decline the session down the ladder.
    public let source: RemuxAudioSource?
    /// One line for the delivery log, naming what was chosen and why.
    public let reason: String
}

public enum RemuxAudioSelection {
    /// Decide where this session's audio comes from.
    ///
    /// - Parameters:
    ///   - selectedStreamIndex: the index the session committed to, or `nil`
    ///     when the user has not chosen (the server's default stands).
    ///   - defaultStreamIndex: the source's `DefaultAudioStreamIndex`.
    ///   - audioStreams: the source's audio streams as the server lists them.
    ///   - matroskaTracks: every track the demuxer read, in file order.
    public static func decide(
        selectedStreamIndex: Int?,
        defaultStreamIndex: Int?,
        audioStreams: [MediaStreamInfo],
        matroskaTracks: [MatroskaTrack],
    ) -> RemuxAudioDecision {
        guard let selectedStreamIndex, selectedStreamIndex != defaultStreamIndex else {
            return defaultDecision(
                defaultStreamIndex: defaultStreamIndex,
                audioStreams: audioStreams,
                matroskaTracks: matroskaTracks,
            )
        }
        return committedDecision(
            streamIndex: selectedStreamIndex,
            audioStreams: audioStreams,
            matroskaTracks: matroskaTracks,
        )
    }

    // MARK: - The default path

    /// The session committed to nothing, so `DefaultAudioStreamIndex`
    /// stands. That is a Jellyfin stream index like any other and resolves
    /// through the same mapping as a selection (#259) — NOT through the
    /// file's `FlagDefault`, which named a different track on real sources
    /// and so put the menu's checkmark on audio that never played.
    ///
    /// Only the two shapes naming no mappable index are decided here, and
    /// both keep the outcome rung 1 has always given them.
    private static func defaultDecision(
        defaultStreamIndex: Int?,
        audioStreams: [MediaStreamInfo],
        matroskaTracks: [MatroskaTrack],
    ) -> RemuxAudioDecision {
        // No declared default: no index to map, and none to name in a
        // transcode request either, so let the server pick its own. The
        // carriable-track test below is inherited from #249 rather than
        // implied by this branch — a `serverTranscoded(nil)` never touches the
        // file's codecs — and is preserved because declining is what rung 1
        // has always done for a file holding no track it could carry.
        guard let defaultStreamIndex else {
            guard matroskaTracks.contains(where: {
                $0.type == .audio && MatroskaFMP4Remuxer.supportedAudioCodecIDs.contains($0.codecID)
            }) else {
                return RemuxAudioDecision(source: nil, reason: "no audio in the source")
            }
            return RemuxAudioDecision(
                source: .serverTranscoded(streamIndex: nil),
                reason: "server transcode of the default stream (server default)",
            )
        }
        // The server names a default the file has no embedded audio for — a
        // sidecar-only source. Nothing to map, but the server transcodes that
        // index perfectly well, and descending instead would cost the session
        // the #99 frameskip for no gain.
        guard audioStreams.contains(where: { $0.type == .audio && !$0.isExternal }) else {
            return RemuxAudioDecision(
                source: .serverTranscoded(streamIndex: defaultStreamIndex),
                reason: "server transcode of the default stream \(defaultStreamIndex) (the server lists no embedded audio)",
            )
        }
        return committedDecision(
            streamIndex: defaultStreamIndex,
            audioStreams: audioStreams,
            matroskaTracks: matroskaTracks,
        )
    }

    // MARK: - The committed index (#252, #259)

    /// One committed stream index — the session's selection, or the server's
    /// default when it selected nothing. Carry it when the mapping is
    /// conclusive AND its codec is carriable; otherwise stay on rung 1 with
    /// a server-side transcode of that index. Never descend for an audio
    /// selection.
    private static func committedDecision(
        streamIndex: Int,
        audioStreams: [MediaStreamInfo],
        matroskaTracks: [MatroskaTrack],
    ) -> RemuxAudioDecision {
        // With no embedded audio there is nothing to carry, and a transcode
        // of a stream the file does not contain would stand up a session
        // doomed to fail on its first segment. Decline instead, exactly as
        // this case did before #252. Only a committed SELECTION reaches this
        // guard: the default path answers that shape above, where the server
        // named the index itself and can transcode it.
        guard audioStreams.contains(where: { $0.type == .audio && !$0.isExternal }) else {
            return RemuxAudioDecision(source: nil, reason: "the source has no embedded audio")
        }
        switch mapTrackNumber(
            forStreamIndex: streamIndex,
            audioStreams: audioStreams,
            matroskaTracks: matroskaTracks,
        ) {
        case let .matched(trackNumber):
            // Filtered to audio deliberately: `mapTrackNumber` only ever names
            // a track from this array's AUDIO subset, and its uniqueness guard
            // checks that subset alone. An unnumbered video `TrackEntry` reads
            // as track 0 too, so an unfiltered lookup could answer with it and
            // report a structural defect in the file's track table as an audio
            // codec decision.
            guard let track = matroskaTracks.first(where: { $0.number == trackNumber && $0.type == .audio }) else {
                return RemuxAudioDecision(
                    source: .serverTranscoded(streamIndex: streamIndex),
                    reason: "server transcode of stream \(streamIndex) (mapped track \(trackNumber) is not an audio track in the file)",
                )
            }
            let codecID = track.codecID
            guard MatroskaFMP4Remuxer.supportedAudioCodecIDs.contains(codecID) else {
                return RemuxAudioDecision(
                    source: .serverTranscoded(streamIndex: streamIndex),
                    reason: "server transcode of stream \(streamIndex) (file track \(trackNumber) is \(codecID), not carriable)",
                )
            }
            return RemuxAudioDecision(
                source: .carried(trackNumber: trackNumber),
                reason: "carried from the file, track \(trackNumber) (\(codecID)) for stream \(streamIndex)",
            )
        case let .ambiguous(why):
            return RemuxAudioDecision(
                source: .serverTranscoded(streamIndex: streamIndex),
                reason: "server transcode of stream \(streamIndex) (\(why))",
            )
        }
    }

    // MARK: - Index mapping

    enum TrackMapping: Equatable {
        case matched(trackNumber: Int)
        case ambiguous(String)
    }

    /// The Matroska track number for a Jellyfin audio stream index, or why
    /// the correspondence could not be trusted.
    static func mapTrackNumber(
        forStreamIndex streamIndex: Int,
        audioStreams: [MediaStreamInfo],
        matroskaTracks: [MatroskaTrack],
    ) -> TrackMapping {
        // Sidecar audio has no `TrackEntry` at all, so it neither occupies a
        // position nor can ever be carried.
        let streams = audioStreams
            .filter { $0.type == .audio && !$0.isExternal }
            .sorted { $0.index < $1.index }
        let mkvAudio = matroskaTracks.filter { $0.type == .audio }

        guard !streams.isEmpty, streams.count == mkvAudio.count else {
            return .ambiguous(
                "the server lists \(pluralized(streams.count, "embedded audio stream")), the file has \(pluralized(mkvAudio.count, "track"))",
            )
        }
        // `MatroskaTrack.number` defaults to 0, so a TrackEntry missing its
        // TrackNumber — or a file with duplicates — would leave the carry
        // lookup free to land on a track other than the one verified here.
        guard Set(mkvAudio.map(\.number)).count == mkvAudio.count else {
            return .ambiguous("the file's audio track numbers are not unique")
        }
        // Check EVERY position, not just the selected one: a shift caused by
        // a track ffmpeg dropped shows up as a contradiction elsewhere in the
        // sequence while the selected position still looks plausible.
        for (position, stream) in streams.enumerated()
            where codecAgreement(jellyfinCodec: stream.codec, matroskaCodecID: mkvAudio[position].codecID) == .contradicts
        {
            return .ambiguous(
                "codec mismatch at audio position \(position): the server says \(stream.codec ?? "?"), the file says \(mkvAudio[position].codecID)",
            )
        }
        guard let position = streams.firstIndex(where: { $0.index == streamIndex }) else {
            if audioStreams.contains(where: { $0.index == streamIndex && $0.isExternal }) {
                return .ambiguous("stream \(streamIndex) is external to the file")
            }
            return .ambiguous("stream \(streamIndex) is not one of the file's audio streams")
        }
        // At the selected position an "unverifiable" codec is not good
        // enough — carrying needs positive agreement.
        let track = mkvAudio[position]
        guard codecAgreement(jellyfinCodec: streams[position].codec, matroskaCodecID: track.codecID) == .agrees else {
            return .ambiguous(
                "cannot corroborate stream \(streamIndex) (\(streams[position].codec ?? "?")) against file track \(track.number) (\(track.codecID))",
            )
        }
        if let streamLanguage = declaredLanguage(streams[position].language),
           let trackLanguage = declaredLanguage(track.language),
           !languagesAgree(streamLanguage, trackLanguage)
        {
            return .ambiguous(
                "language mismatch at stream \(streamIndex): the server says \(streamLanguage), file track \(track.number) says \(trackLanguage)",
            )
        }
        return .matched(trackNumber: track.number)
    }

    // MARK: - Codec correspondence

    /// Jellyfin codec name -> the Matroska CodecID prefix it must appear as.
    /// Prefixes, because Matroska qualifies most of them (`A_AAC/MPEG4/LC`,
    /// `A_PCM/INT/LIT`). Codecs the remux cannot carry are listed too: the
    /// table's job is corroborating the POSITION, and carriability is decided
    /// separately from the exact CodecID.
    static let matroskaCodecPrefixes: [String: String] = [
        "aac": "A_AAC",
        "ac3": "A_AC3",
        "eac3": "A_EAC3",
        "flac": "A_FLAC",
        "dts": "A_DTS",
        "dca": "A_DTS",
        "truehd": "A_TRUEHD",
        "mp3": "A_MPEG/L3",
        "mp2": "A_MPEG/L2",
        "opus": "A_OPUS",
        "vorbis": "A_VORBIS",
        "alac": "A_ALAC",
    ]

    enum CodecAgreement: Equatable {
        /// Both sides name the same codec.
        case agrees
        /// Both sides are spellings we know, and they name different codecs.
        case contradicts
        /// At least one side is a spelling this table does not know, so the
        /// pair says nothing either way.
        case unverifiable
    }

    static func codecAgreement(jellyfinCodec: String?, matroskaCodecID: String) -> CodecAgreement {
        guard let expected = matroskaPrefix(forJellyfinCodec: jellyfinCodec) else { return .unverifiable }
        let codecID = matroskaCodecID.uppercased()
        if codecID.hasPrefix(expected) {
            return .agrees
        }
        // Only a CodecID this table recognises can contradict; an exotic one
        // leaves the position unverified rather than refuted.
        guard matroskaCodecPrefixes.values.contains(where: { codecID.hasPrefix($0) }) else { return .unverifiable }
        return .contradicts
    }

    private static func matroskaPrefix(forJellyfinCodec codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        // ffprobe spells linear PCM as a family (pcm_s16le, pcm_s24be, ...).
        if codec.hasPrefix("pcm_") {
            return "A_PCM"
        }
        return matroskaCodecPrefixes[codec]
    }

    // MARK: - Language corroboration

    /// A language only corroborates when it is actually declared; `und` is
    /// the Matroska default for "not stated", not a claim.
    ///
    /// The two sides are routinely spelled differently for the same
    /// language: the demuxer reads Matroska's legacy `Language` element,
    /// which is ISO 639-2, while Jellyfin's side comes from ffprobe, which
    /// prefers `LanguageBCP47` and so tends to be 639-1. Canonicalizing both
    /// through ICU is what makes them comparable — `ger`, `deu` and `de` all
    /// land on `de`. Comparing the raw strings, by equality or by prefix,
    /// gets it wrong in both directions: `de`/`ger` share no prefix and
    /// would read as a contradiction, while `sl` (Slovenian) is a prefix of
    /// `slo` (Slovak) and would read as agreement.
    private static func declaredLanguage(_ language: String?) -> String? {
        guard let language = language?.lowercased(), !language.isEmpty else { return nil }
        let stripped = language.split(separator: "-").first.map(String.init) ?? language
        guard stripped != "und", stripped != "undefined" else { return nil }
        return Locale.canonicalLanguageIdentifier(from: stripped)
    }

    /// Canonical identifiers compare by equality; anything else is a genuine
    /// disagreement and falls back to the server transcode — the safe
    /// direction.
    private static func languagesAgree(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }

    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

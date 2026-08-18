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
    /// Set when the DEFAULT path carries a track and the index mapping
    /// confidently names a different Matroska track for the default stream
    /// index. Instrumentation only — it never changes the decision,
    /// because the default path's behaviour is deliberately frozen. A device
    /// log carrying this is evidence the positional correspondence is wrong
    /// somewhere real.
    public let defaultPickMismatch: Int?
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
        return nonDefaultDecision(
            selectedStreamIndex: selectedStreamIndex,
            audioStreams: audioStreams,
            matroskaTracks: matroskaTracks,
        )
    }

    // MARK: - The default path (behaviour frozen)

    /// Exactly what rung 1 did before #252: carry the remuxer's own default
    /// pick when the server says the default track's codec is carriable,
    /// otherwise transcode the default index server-side, otherwise decline.
    /// The mapping runs here too, but only to log a disagreement.
    private static func defaultDecision(
        defaultStreamIndex: Int?,
        audioStreams: [MediaStreamInfo],
        matroskaTracks: [MatroskaTrack],
    ) -> RemuxAudioDecision {
        let pick = MatroskaFMP4Remuxer.selectAudioTrack(from: matroskaTracks)
        let defaultCodec = audioStreams.first { $0.index == defaultStreamIndex }?.codec?.lowercased()

        if let pick, carriableJellyfinCodecs.contains(defaultCodec ?? "") {
            // Only meaningful when the default path actually CARRIES: the
            // pick deliberately skips an uncarriable default (#251), and that
            // is not a disagreement about which track the default is.
            var mismatch: Int?
            if let defaultStreamIndex,
               case let .matched(mapped) = mapTrackNumber(
                   forStreamIndex: defaultStreamIndex,
                   audioStreams: audioStreams,
                   matroskaTracks: matroskaTracks,
               ), mapped != pick.number
            {
                mismatch = mapped
            }
            return RemuxAudioDecision(
                source: .carried(trackNumber: pick.number),
                reason: "carried from the file, track \(pick.number) (\(pick.codecID))",
                defaultPickMismatch: mismatch,
            )
        }
        // The file's default is one the remux can neither carry nor
        // AVFoundation decode (DTS/TrueHD): take the external-audio path
        // (#249) rather than substitute a different track.
        if defaultStreamIndex != nil || pick != nil {
            return RemuxAudioDecision(
                source: .serverTranscoded(streamIndex: defaultStreamIndex),
                reason: "server transcode of the default stream \(describe(defaultStreamIndex)) (\(defaultCodec ?? "unknown codec"))",
                defaultPickMismatch: nil,
            )
        }
        return RemuxAudioDecision(source: nil, reason: "no audio in the source", defaultPickMismatch: nil)
    }

    // MARK: - The non-default path (#252)

    /// A committed track that is not the default. Carry it when the mapping
    /// is conclusive AND its codec is carriable; otherwise stay on rung 1
    /// with a server-side transcode of that index. Never descend for an
    /// audio selection.
    private static func nonDefaultDecision(
        selectedStreamIndex: Int,
        audioStreams: [MediaStreamInfo],
        matroskaTracks: [MatroskaTrack],
    ) -> RemuxAudioDecision {
        // With no embedded audio there is nothing to carry, and a transcode
        // of a stream the file does not contain would stand up a session
        // doomed to fail on its first segment. Decline instead, exactly as
        // this case did before #252.
        guard audioStreams.contains(where: { $0.type == .audio && !$0.isExternal }) else {
            return RemuxAudioDecision(source: nil, reason: "the source has no embedded audio", defaultPickMismatch: nil)
        }
        switch mapTrackNumber(
            forStreamIndex: selectedStreamIndex,
            audioStreams: audioStreams,
            matroskaTracks: matroskaTracks,
        ) {
        case let .matched(trackNumber):
            let track = matroskaTracks.first { $0.number == trackNumber }
            let codecID = track?.codecID ?? ""
            guard MatroskaFMP4Remuxer.supportedAudioCodecIDs.contains(codecID) else {
                return RemuxAudioDecision(
                    source: .serverTranscoded(streamIndex: selectedStreamIndex),
                    reason: "server transcode of stream \(selectedStreamIndex) (file track \(trackNumber) is \(codecID), not carriable)",
                    defaultPickMismatch: nil,
                )
            }
            return RemuxAudioDecision(
                source: .carried(trackNumber: trackNumber),
                reason: "carried from the file, track \(trackNumber) (\(codecID)) for stream \(selectedStreamIndex)",
                defaultPickMismatch: nil,
            )
        case let .ambiguous(why):
            return RemuxAudioDecision(
                source: .serverTranscoded(streamIndex: selectedStreamIndex),
                reason: "server transcode of stream \(selectedStreamIndex) (\(why))",
                defaultPickMismatch: nil,
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

    /// Jellyfin stream-info codec spellings the remux can carry —
    /// `MatroskaFMP4Remuxer.supportedAudioCodecIDs` seen from the server's
    /// metadata instead of the Matroska track header. The default path keys
    /// on these (the rule it has always used); the non-default path keys on
    /// the CodecID it is about to carry.
    static let carriableJellyfinCodecs: Set<String> = ["aac", "ac3", "eac3", "flac"]

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

    private static func describe(_ index: Int?) -> String {
        index.map(String.init) ?? "(server default)"
    }

    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

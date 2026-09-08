import Foundation

/// Parameters for building a stream URL
public struct StreamParameters: Sendable, Equatable {
    /// The item to stream
    public let itemId: String

    /// The media source to stream from
    public let mediaSourceId: String?

    /// The play session identifier from PlaybackInfo
    public let playSessionId: String?

    /// Audio stream index to play (server default when nil)
    public let audioStreamIndex: Int?

    /// Subtitle stream index to deliver or burn in (none when nil)
    public let subtitleStreamIndex: Int?

    public init(
        itemId: String,
        mediaSourceId: String? = nil,
        playSessionId: String? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
    ) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
    }
}

/// A stream URL paired with how the server will deliver it, so playback
/// reporting can state the true play method
public struct StreamResolution: Sendable, Equatable {
    /// The URL to hand to AVPlayer
    public let url: URL

    /// How the server delivers this stream
    public let playMethod: PlayMethod

    public init(url: URL, playMethod: PlayMethod) {
        self.url = url
        self.playMethod = playMethod
    }
}

/// Builds Jellyfin streaming URLs
///
/// Pure URL construction with no networking, so it is fully unit-testable.
/// Direct-play-capable sources stream the original file from the static
/// endpoint; everything else uses the HLS universal endpoint, where the
/// server remuxes when the codecs are compatible and transcodes otherwise,
/// and the playlist spans the full duration so AVPlayer can seek anywhere.
enum StreamURLBuilder {
    /// Audio bitrate ceiling carved out of the streaming budget; the rest goes
    /// to video.
    ///
    /// This is a *ceiling*, not a target — the server stream-copies any audio
    /// that fits under it and only re-encodes what doesn't. So it must sit above
    /// the real-world lossy multichannel rates, or tracks that could have passed
    /// through untouched get needlessly re-encoded.
    ///
    /// It used to be 192 kbps (the split the server computes for its own
    /// re-encodes), which silently destroyed **every Dolby Atmos E-AC-3 track**:
    /// those run 384–768 kbps, so the ceiling forced a re-encode to AAC and the
    /// object metadata with it. Measured 2026-08-02 against Jellyfin 10.11.11 —
    /// with the identical codec list and only this value raised, the server
    /// switched from `AudioCodec=aac` to `AudioCodec=copy` and delivered `ec-3`
    /// (#222, docs/PLAYBACK_MATRIX.md).
    ///
    /// 1.5 Mbps covers E-AC-3 and AC-3 comfortably. It cannot let an
    /// undecodable track through: `AudioCodec` below already bounds copying to
    /// `aac,ac3,eac3`, so TrueHD and DTS still re-encode regardless of headroom.
    static let audioBitrate = 1_536_000

    /// Jellyfin's own ceiling on audio for a given total budget, mirrored
    /// from `StreamBuilder.GetMaxAudioBitrateForTotalBitrate`
    /// (jellyfin/jellyfin, `MediaBrowser.Model/Dlna/StreamBuilder.cs`, lines
    /// 730-760 on `master`; reached from `GetAudioBitrate` at line 747 as
    /// `Math.Min(GetMaxAudioBitrateForTotalBitrate(maxTotalBitrate),
    /// defaultBitrate)`).
    ///
    /// Mirrored rather than invented so a capped request is split the way
    /// the server would have split it — the alternative is two different
    /// notions of "how much of this budget is audio" negotiating with each
    /// other.
    static func serverAudioBitrateCeiling(forTotal total: Int) -> Int {
        switch total {
        case ...640_000: 128_000
        case ...2_000_000: 384_000
        case ...3_000_000: 448_000
        case ...4_000_000: 640_000
        case ...5_000_000: 768_000
        case ...10_000_000: 1_536_000
        case ...15_000_000: 2_304_000
        case ...20_000_000: 3_584_000
        default: 7_168_000
        }
    }

    /// Split a total streaming budget into the video and audio ceilings the
    /// stream URL carries. The two together always equal the budget.
    ///
    /// `audioBitrate` above is what this client wants for audio; the table
    /// is what the budget affords. The reservation cannot be unconditional
    /// once the budget is a user-set cap (#168): against a 2 Mbps ceiling a
    /// fixed 1.5 Mbps of audio is most of the money, and the old
    /// `max(total - audio, audio)` split emitted 1.5 Mbps of video *plus*
    /// 1.5 Mbps of audio — a 3 Mbps request against the 2 Mbps ceiling the
    /// viewer had just asked for, which is the over-ask this issue exists to
    /// stop.
    ///
    /// The table reaches this client's 1.5 Mbps ceiling once the budget passes
    /// 5 Mbps, so the 8 Mbps tier and every tier above it reserve the unchanged
    /// `audioBitrate` and every lossy multichannel track still passes
    /// through untouched (#222). At 4 Mbps the ceiling is 640 kbps, which
    /// still carries AC-3 but re-encodes the upper half of E-AC-3's range;
    /// at 2 Mbps it is 384 kbps, where only the lowest-rate tracks survive.
    /// Re-encoding to AAC is the right trade at those budgets — the link
    /// cannot carry both streams at full rate.
    ///
    /// The old video floor is deliberately gone: it existed only because the
    /// audio reservation was fixed, and it is what put the sum over budget.
    static func bitrateSplit(forTotal total: Int) -> (video: Int, audio: Int) {
        let audio = min(audioBitrate, serverAudioBitrateCeiling(forTotal: total))
        return (video: total - audio, audio: audio)
    }

    /// Build an HLS universal stream URL: `/Videos/{itemId}/master.m3u8`
    ///
    /// The master playlist (not `main.m3u8`, which is the video-only media
    /// playlist) is required for subtitles: it is the only endpoint that
    /// advertises text subtitle tracks as WebVTT renditions AVPlayer can
    /// select.
    ///
    /// It is also required unconditionally by the loopback interposer.
    /// `PlaybackLocalServer` works on this playlist: it appends a synthesized
    /// I-frame rendition (which only a *master* playlist can carry — handing
    /// it a media playlist used to crash MediaToolbox outright,
    /// `FigMediaPlaylistGetTargetDuration` on a null playlist) and redirects
    /// subtitle renditions through its map-stripping routes. So do not make
    /// this endpoint conditional.
    ///
    /// Bitrate parameters must be sent too — without them the server
    /// re-encodes at a tiny default resolution whenever it can't stream-copy
    /// (e.g. subtitle burn-in).
    ///
    /// - Parameters:
    ///   - serverURL: The server base URL (path prefixes are preserved)
    ///   - accessToken: The authentication token, sent as `api_key`
    ///   - deviceId: The device identifier reported to the server
    ///   - parameters: Item and stream selection parameters
    ///   - subtitleMethod: How the selected subtitle should be delivered
    ///   - assumeInterposer: Whether `PlaybackLocalServer` will carry this
    ///     session (the normal case); false is the degraded path when the
    ///     loopback listener could not start
    ///   - hevcRangeTypes: Video range types the engine's display pipeline
    ///     handles, sent on the HEVC passthrough path as the codec-scoped
    ///     `hevc-rangetype` stream option (comma-separated, the server's own
    ///     TranscodingUrl serialization). Comes from
    ///     `PlaybackCapabilities.hevcRangeTypesParameter`, the same stored
    ///     declaration the derived DeviceProfile's `VideoRangeType`
    ///     condition serializes — so PlaybackInfo negotiation and the
    ///     hand-built stream URL reach the same verdict by construction.
    ///     An undeclared client is assumed SDR-only and the server
    ///     tone-maps every HDR source via a below-realtime software
    ///     re-encode (#146).
    ///   - maxStreamingBitrate: Total streaming budget in bits per second,
    ///     split into the video and audio ceilings by `bitrateSplit`. Comes
    ///     from the same `PlaybackCapabilities` the PlaybackInfo request
    ///     declared, so the negotiated ceiling and the built URL agree —
    ///     including when a user-set cap (#168) narrowed it.
    ///   - eTag: Optional media source tag for cache validation
    /// - Returns: The stream URL, or nil if construction fails
    static func hlsURL(
        serverURL: URL,
        accessToken: String,
        deviceId: String,
        parameters: StreamParameters,
        subtitleMethod: SubtitleDeliveryMethod = .hls,
        assumeInterposer: Bool = true,
        sourceVideoCodec: String? = nil,
        hevcRangeTypes: String,
        maxStreamingBitrate: Int,
        eTag: String? = nil,
    ) -> URL? {
        // The segment container is chosen by the SOURCE video codec, because
        // Jellyfin's fMP4 stream-*copy* segments on the source's keyframes and
        // yields irregular fragments AVPlayer hitches on (a periodic skip).
        //
        // - Non-HEVC (H.264 and everything else): MPEG-TS. A TS copy segments
        //   cleanly and plays smooth; anything the server cannot copy is
        //   transcoded to H.264, which TS carries fine.
        // - HEVC: fMP4. Apple's HLS stack decodes HEVC solely from fMP4 (HEVC
        //   in MPEG-TS is audio over a black screen, #73), so HEVC stays an
        //   fMP4 passthrough. That path still shows the copy-fragment skip; a
        //   smooth HEVC path requires a re-encode and is tracked separately.
        //
        // Container also drives WebVTT timestamp-map handling: Jellyfin's map
        // aligns cues against TS PTS, so on TS it is kept as-is while on fMP4
        // (zero-based) PlaybackLocalServer strips it (#90). On the degraded
        // path (no interposer to strip), an HEVC text-subtitle session is
        // therefore pinned to TS + H.264, where the map lines up untouched.
        // Match both spellings the server may report ("hevc" and "h265"), so
        // an HEVC source is never mistaken for one to re-encode into H.264.
        let sourceIsHEVC = ["hevc", "h265"].contains {
            sourceVideoCodec?.caseInsensitiveCompare($0) == .orderedSame
        }
        let degradedHEVCSubtitle = sourceIsHEVC && !assumeInterposer
            && subtitleMethod == .hls && parameters.subtitleStreamIndex != nil
        // Burn-in always re-encodes to composite the track; offering HEVC there
        // invites a software HEVC encode too slow to deliver segments (observed:
        // hvc1 burn-in sessions hung at position 0 indefinitely).
        let hevcPassthrough = sourceIsHEVC && subtitleMethod != .encode && !degradedHEVCSubtitle
        let segmentContainer = hevcPassthrough ? "mp4" : "ts"
        let videoCodec = hevcPassthrough ? "hevc,h264" : "h264"

        // Append to the server URL rather than overwriting the path,
        // so servers hosted under a path prefix (e.g. /jellyfin) keep working
        let endpoint = serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(parameters.itemId)
            .appendingPathComponent("master.m3u8")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let budget = bitrateSplit(forTotal: maxStreamingBitrate)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "VideoCodec", value: videoCodec),
            URLQueryItem(name: "AudioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "SegmentContainer", value: segmentContainer),
            URLQueryItem(name: "MinSegments", value: "2"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "true"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "SubtitleMethod", value: subtitleMethod.rawValue),
            URLQueryItem(name: "VideoBitrate", value: String(budget.video)),
            URLQueryItem(name: "AudioBitrate", value: String(budget.audio)),
        ]

        // Only the passthrough path carries an HEVC copy the range
        // declaration can unlock; the TS path is an H.264 re-encode where
        // tone-mapping HDR down to SDR is the correct outcome.
        if hevcPassthrough {
            queryItems.append(URLQueryItem(name: "hevc-rangetype", value: hevcRangeTypes))
        }

        if let mediaSourceId = parameters.mediaSourceId {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        if let playSessionId = parameters.playSessionId {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: playSessionId))
        }
        if let audioStreamIndex = parameters.audioStreamIndex {
            queryItems.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        // Burn-in needs the index (the server composites that exact track),
        // and so does the degraded text path (the app owns delivery there).
        // On the normal text path AVKit owns selection and the master
        // advertises every text rendition regardless, so the index is
        // omitted — subtitle state can never change the stream shape.
        if let subtitleStreamIndex = parameters.subtitleStreamIndex,
           subtitleMethod == .encode || !assumeInterposer
        {
            queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(subtitleStreamIndex)))
        }
        if let eTag {
            queryItems.append(URLQueryItem(name: "Tag", value: eTag))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Build a direct-play URL for the original file:
    /// `/Videos/{itemId}/stream[.{container}]?static=true`
    ///
    /// Stream selection parameters are deliberately absent — a static file
    /// always plays its embedded default tracks, and the play-method decision
    /// (`MediaSource.playMethod`) only chooses direct play when the requested
    /// tracks are the defaults.
    ///
    /// - Parameters:
    ///   - serverURL: The server base URL (path prefixes are preserved)
    ///   - accessToken: The authentication token, sent as `api_key`
    ///   - deviceId: The device identifier reported to the server
    ///   - parameters: Item and session parameters (stream indices ignored)
    ///   - container: The source container, appended as the path extension so
    ///     AVPlayer can infer the file type (skipped when unknown or a list)
    ///   - eTag: Optional media source tag for cache validation
    /// - Returns: The stream URL, or nil if construction fails
    static func directPlayURL(
        serverURL: URL,
        accessToken: String,
        deviceId: String,
        parameters: StreamParameters,
        container: String? = nil,
        eTag: String? = nil,
    ) -> URL? {
        var endpoint = serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(parameters.itemId)
            .appendingPathComponent("stream")

        // MediaSourceInfo.container can be a comma-separated list; only a
        // single concrete container makes a valid file extension
        if let container, !container.isEmpty, !container.contains(",") {
            endpoint = endpoint.appendingPathExtension(container)
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId),
        ]

        if let mediaSourceId = parameters.mediaSourceId {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        if let playSessionId = parameters.playSessionId {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: playSessionId))
        }
        if let eTag {
            queryItems.append(URLQueryItem(name: "Tag", value: eTag))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Build a trickplay tile-sheet URL:
    /// `/Videos/{itemId}/Trickplay/{width}/{index}.jpg`
    ///
    /// Tile sheets require authentication, so this follows the stream-URL
    /// pattern (`api_key` + `DeviceId`) rather than the tag-based,
    /// unauthenticated artwork pattern.
    ///
    /// - Parameters:
    ///   - serverURL: The server base URL (path prefixes are preserved)
    ///   - accessToken: The authentication token, sent as `api_key`
    ///   - deviceId: The device identifier reported to the server
    ///   - itemId: The item the trickplay data belongs to
    ///   - width: The resolution key (`TrickplayInfo.widthKey`)
    ///   - tileIndex: The tile sheet index (`TrickplayTileLocation.tileIndex`)
    ///   - mediaSourceId: The media source the manifest entry is keyed by
    /// - Returns: The tile sheet URL, or nil if construction fails
    static func trickplayTileURL(
        serverURL: URL,
        accessToken: String,
        deviceId: String,
        itemId: String,
        width: Int,
        tileIndex: Int,
        mediaSourceId: String?,
    ) -> URL? {
        let endpoint = serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Trickplay")
            .appendingPathComponent(String(width))
            .appendingPathComponent("\(tileIndex).jpg")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId),
        ]

        if let mediaSourceId {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Build the audio-only HLS endpoints for an external-audio remux
    /// session (#249): `/Audio/{itemId}/main.m3u8` plus its
    /// `hls1/main/{index}` segment route. Probed 2026-08-17 against
    /// Jellyfin 10.11.11: the endpoint accepts movie items, serves 3-second
    /// MPEG-TS segments, and a segment-index jump restarts ffmpeg with
    /// `-ss` exactly at that segment's boundary — which is what makes the
    /// audio fetchable at the offsets the remux plan needs.
    ///
    /// The segment route requires the same query set as the playlist (the
    /// transcode job is keyed on it) plus `runtimeTicks` and
    /// `actualSegmentLengthTicks`, which tell the server where a fresh run
    /// must seek.
    static func audioHLSStream(
        serverURL: URL,
        accessToken: String,
        deviceId: String,
        parameters: StreamParameters,
        audioStreamIndex: Int?,
        audioBitrate: Int,
    ) -> AudioHLSStream? {
        let base = serverURL
            .appendingPathComponent("Audio")
            .appendingPathComponent(parameters.itemId)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "audioBitRate", value: String(audioBitrate)),
            URLQueryItem(name: "segmentContainer", value: "aac"),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId),
        ]
        if let audioStreamIndex {
            queryItems.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        if let mediaSourceId = parameters.mediaSourceId {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        if let playSessionId = parameters.playSessionId {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: playSessionId))
        }

        guard var playlistComponents = URLComponents(
            url: base.appendingPathComponent("main.m3u8"),
            resolvingAgainstBaseURL: false,
        ) else { return nil }
        playlistComponents.queryItems = queryItems
        guard let playlistURL = playlistComponents.url else { return nil }

        return AudioHLSStream(
            playlistURL: playlistURL,
            segmentBase: base.appendingPathComponent("hls1").appendingPathComponent("main"),
            queryItems: queryItems,
        )
    }
}

/// The two audio-only HLS routes an external-audio session needs, sharing
/// one query set so every segment lands on the same transcode job.
public struct AudioHLSStream: Sendable, Equatable {
    public let playlistURL: URL
    let segmentBase: URL
    let queryItems: [URLQueryItem]

    public init(playlistURL: URL, segmentBase: URL, queryItems: [URLQueryItem]) {
        self.playlistURL = playlistURL
        self.segmentBase = segmentBase
        self.queryItems = queryItems
    }

    /// The URL of one media segment. `runtimeTicks` is the segment's start
    /// and `segmentLengthTicks` its planned length, both in server ticks
    /// (100 ns); the segment extension mirrors `segmentContainer`.
    public func segmentURL(index: Int, runtimeTicks: Int64, segmentLengthTicks: Int64) -> URL? {
        guard var components = URLComponents(
            url: segmentBase.appendingPathComponent("\(index).aac"),
            resolvingAgainstBaseURL: false,
        ) else { return nil }
        components.queryItems = queryItems + [
            URLQueryItem(name: "runtimeTicks", value: String(runtimeTicks)),
            URLQueryItem(name: "actualSegmentLengthTicks", value: String(segmentLengthTicks)),
        ]
        return components.url
    }
}

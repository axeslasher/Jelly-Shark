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
    /// Audio bitrate ceiling carved out of the streaming budget when the
    /// server re-encodes; the rest goes to video. Matches the split the
    /// server itself computes in PlaybackInfo's TranscodingUrl.
    static let audioBitrate = 192_000

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
    ///   - maxStreamingBitrate: Total streaming budget in bits per second
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
        maxStreamingBitrate: Int = JellyfinClient.maxStreamingBitrate,
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
            URLQueryItem(name: "VideoBitrate", value: String(max(maxStreamingBitrate - audioBitrate, audioBitrate))),
            URLQueryItem(name: "AudioBitrate", value: String(audioBitrate)),
        ]

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
}

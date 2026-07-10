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
        subtitleStreamIndex: Int? = nil
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
struct StreamURLBuilder {
    /// Build an HLS universal stream URL: `/Videos/{itemId}/main.m3u8`
    ///
    /// - Parameters:
    ///   - serverURL: The server base URL (path prefixes are preserved)
    ///   - accessToken: The authentication token, sent as `api_key`
    ///   - deviceId: The device identifier reported to the server
    ///   - parameters: Item and stream selection parameters
    ///   - eTag: Optional media source tag for cache validation
    /// - Returns: The stream URL, or nil if construction fails
    static func hlsURL(
        serverURL: URL,
        accessToken: String,
        deviceId: String,
        parameters: StreamParameters,
        eTag: String? = nil
    ) -> URL? {
        // Append to the server URL rather than overwriting the path,
        // so servers hosted under a path prefix (e.g. /jellyfin) keep working
        let endpoint = serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(parameters.itemId)
            .appendingPathComponent("main.m3u8")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "VideoCodec", value: "hevc,h264"),
            URLQueryItem(name: "AudioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "SegmentContainer", value: "mp4"),
            URLQueryItem(name: "MinSegments", value: "2"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "true"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "SubtitleMethod", value: "Hls"),
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
        if let subtitleStreamIndex = parameters.subtitleStreamIndex {
            queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(subtitleStreamIndex)))
        }
        if let eTag = eTag {
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
        eTag: String? = nil
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
        if let eTag = eTag {
            queryItems.append(URLQueryItem(name: "Tag", value: eTag))
        }

        components.queryItems = queryItems
        return components.url
    }
}

import Foundation

/// Playback information for a media item, returned by the server's PlaybackInfo endpoint
///
/// This is a clean, app-specific representation of playback data.
/// It is created from the SDK's PlaybackInfoResponse via the adapter layer.
public struct PlaybackSessionInfo: Sendable, Equatable {
    /// Server-assigned play session identifier, used for playback reporting
    public let playSessionId: String?

    /// Media sources available for this item
    public let mediaSources: [MediaSource]

    /// The media source to play by default
    public var defaultMediaSource: MediaSource? {
        mediaSources.first
    }

    public init(playSessionId: String? = nil, mediaSources: [MediaSource] = []) {
        self.playSessionId = playSessionId
        self.mediaSources = mediaSources
    }
}

/// A playable source for a media item (file/version with its streams)
public struct MediaSource: Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for this media source
    public let id: String

    /// Container format (e.g., "mkv", "mp4")
    public let container: String?

    /// Codec of the primary video stream (e.g., "hevc", "h264"), used to pick
    /// the HLS segment container (HEVC → fMP4, else → TS)
    public let videoCodec: String?

    /// Whether the source can be played directly without server processing
    public let supportsDirectPlay: Bool

    /// Whether the source can be remuxed by the server
    public let supportsDirectStream: Bool

    /// Whether the source can be transcoded by the server
    public let supportsTranscoding: Bool

    /// Server-relative transcoding URL, if the server prepared one
    public let transcodingURL: String?

    /// Entity tag for this source, passed to stream URLs for cache validation
    public let eTag: String?

    /// Runtime in ticks (1 tick = 100 nanoseconds)
    public let runTimeTicks: Int64?

    /// Index of the default audio stream
    public let defaultAudioStreamIndex: Int?

    /// Index of the default subtitle stream
    public let defaultSubtitleStreamIndex: Int?

    /// Audio streams available in this source
    public let audioStreams: [MediaStreamInfo]

    /// Subtitle streams available in this source
    public let subtitleStreams: [MediaStreamInfo]

    public init(
        id: String,
        container: String? = nil,
        videoCodec: String? = nil,
        supportsDirectPlay: Bool = false,
        supportsDirectStream: Bool = false,
        supportsTranscoding: Bool = false,
        transcodingURL: String? = nil,
        eTag: String? = nil,
        runTimeTicks: Int64? = nil,
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil,
        audioStreams: [MediaStreamInfo] = [],
        subtitleStreams: [MediaStreamInfo] = [],
    ) {
        self.id = id
        self.container = container
        self.videoCodec = videoCodec
        self.supportsDirectPlay = supportsDirectPlay
        self.supportsDirectStream = supportsDirectStream
        self.supportsTranscoding = supportsTranscoding
        self.transcodingURL = transcodingURL
        self.eTag = eTag
        self.runTimeTicks = runTimeTicks
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
        self.audioStreams = audioStreams
        self.subtitleStreams = subtitleStreams
    }
}

// MARK: - Play Method

/// How the client delivers a media source
public enum PlayMethod: Sendable, Equatable {
    /// The original file streamed as-is, no server processing
    case directPlay

    /// HLS with server-side stream copy into compatible segments (remux)
    case directStream

    /// HLS with server-side re-encode
    case transcode
}

/// How the server should deliver a selected subtitle stream over HLS
public enum SubtitleDeliveryMethod: String, Sendable, Equatable {
    /// Text subtitles served as WebVTT renditions in the master playlist
    case hls = "Hls"

    /// Image subtitles burned into the video (forces a re-encode)
    case encode = "Encode"
}

public extension MediaSource {
    /// The subtitle stream with the given source-relative index, if any
    func subtitleStream(at index: Int?) -> MediaStreamInfo? {
        guard let index else { return nil }
        return subtitleStreams.first { $0.index == index }
    }

    /// Whether delivering the given subtitle selection requires burning it
    /// into the video. Image-based formats (PGS, VobSub) cannot be served as
    /// HLS text renditions; the server must re-encode with them composited.
    /// An index that doesn't resolve to a known stream is treated as text.
    func subtitleRequiresBurnIn(at index: Int?) -> Bool {
        guard let stream = subtitleStream(at: index) else { return false }
        return !stream.isTextSubtitleStream
    }

    /// Pick the playback method for this source given the requested tracks.
    ///
    /// Direct play requires default tracks: a static file cannot honor
    /// server-side stream selection (and AVPlayer track selection on
    /// progressive files is unreliable), so explicit choices route through
    /// the HLS endpoint where AudioStreamIndex/SubtitleStreamIndex apply.
    /// A subtitle that needs burn-in is always a transcode: the server
    /// re-encodes the video to composite it, whatever the flags claim.
    func playMethod(audioStreamIndex: Int?, subtitleStreamIndex: Int?) -> PlayMethod {
        if subtitleRequiresBurnIn(at: subtitleStreamIndex) {
            return .transcode
        }
        let usesDefaultAudio = audioStreamIndex == nil || audioStreamIndex == defaultAudioStreamIndex
        if supportsDirectPlay, usesDefaultAudio, subtitleStreamIndex == nil {
            return .directPlay
        }
        if supportsDirectStream {
            return .directStream
        }
        return .transcode
    }
}

/// A single stream (audio, subtitle, video) within a media source
public struct MediaStreamInfo: Sendable, Equatable, Hashable {
    /// The kind of stream
    public enum StreamType: String, Sendable {
        case audio
        case subtitle
        case video
        case unknown
    }

    /// Stream index within the media source, used for stream selection
    public let index: Int

    /// The kind of stream
    public let type: StreamType

    /// Human-readable title (e.g., "English - AAC - Stereo")
    public let displayTitle: String?

    /// Language code (e.g., "eng")
    public let language: String?

    /// Codec name (e.g., "aac", "subrip")
    public let codec: String?

    /// Whether this is the default stream of its type
    public let isDefault: Bool

    /// Whether the stream is external to the media file (e.g., sidecar subtitles)
    public let isExternal: Bool

    /// Whether the subtitle stream is text-based (deliverable without burn-in)
    public let isTextSubtitleStream: Bool

    /// Server-relative delivery URL for external streams
    public let deliveryURL: String?

    public init(
        index: Int,
        type: StreamType,
        displayTitle: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false,
        isExternal: Bool = false,
        isTextSubtitleStream: Bool = false,
        deliveryURL: String? = nil,
    ) {
        self.index = index
        self.type = type
        self.displayTitle = displayTitle
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isExternal = isExternal
        self.isTextSubtitleStream = isTextSubtitleStream
        self.deliveryURL = deliveryURL
    }
}

// MARK: - Ticks Conversion

/// Conversions between Jellyfin ticks (1 tick = 100 nanoseconds) and seconds
public enum PlaybackTicks {
    /// Number of ticks in one second
    public static let ticksPerSecond: Int64 = 10_000_000

    /// Convert ticks to seconds
    public static func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) / Double(ticksPerSecond)
    }

    /// Convert seconds to ticks
    public static func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(seconds * Double(ticksPerSecond))
    }
}

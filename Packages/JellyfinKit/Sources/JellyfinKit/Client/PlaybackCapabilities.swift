import Foundation

/// What a playback engine can decode and render, declared in Jellyfin's
/// vocabulary but without Jellyfin's wire types (#85).
///
/// The `DeviceProfile` sent with every PlaybackInfo request is **derived**
/// from this declaration rather than hardcoded: every claim in the profile
/// is a property of the engine that will decode the stream — not of
/// Jellyfin, and not of the app. A client built on a different engine
/// declares different capabilities and the server negotiates against those;
/// a hardcoded profile would lie to the server on that client's behalf.
///
/// This mirrors only what the profile actually uses. Condition `value`
/// strings are the server's own grammar (`|`-separated alternatives),
/// carried verbatim so the derived profile is the moved original, not a
/// re-encoding of it.
public struct PlaybackCapabilities: Sendable, Equatable {
    /// Client name reported in the profile
    public var name: String

    /// Streaming bitrate ceiling declared to the server.
    ///
    /// PlaybackInfo requests MUST carry this: when the field is omitted the
    /// server falls back to a low default cap and reports
    /// `SupportsDirectPlay=false` for most real-world files (observed
    /// cutoff ~2.5 Mbps against Jellyfin 10.10).
    public var maxStreamingBitrate: Int

    /// One blanket direct-play claim: these containers with these codecs
    /// play as the original file, subject to `videoCodecRules`
    public struct DirectPlayRule: Sendable, Equatable {
        public var containers: [String]
        public var videoCodecs: [String]
        public var audioCodecs: [String]

        public init(containers: [String], videoCodecs: [String], audioCodecs: [String]) {
            self.containers = containers
            self.videoCodecs = videoCodecs
            self.audioCodecs = audioCodecs
        }
    }

    public var directPlay: [DirectPlayRule]

    /// A condition a source's video stream must (or should) meet for the
    /// blanket claims in `directPlay` to hold
    public struct VideoCodecCondition: Sendable, Equatable {
        public enum Property: Sendable, Equatable {
            case videoCodecTag
            case videoRangeType
            case videoBitDepth
            case videoProfile
        }

        public enum Comparison: Sendable, Equatable {
            case equalsAny
            case lessThanEqual
        }

        public var property: Property
        public var comparison: Comparison

        /// Condition value in the server's grammar (`|`-separated
        /// alternatives for `equalsAny`), carried verbatim into the profile
        public var value: String

        /// False leaves sources with an unprobed property playable rather
        /// than rejecting them outright
        public var isRequired: Bool

        public init(property: Property, comparison: Comparison, value: String, isRequired: Bool) {
            self.property = property
            self.comparison = comparison
            self.value = value
            self.isRequired = isRequired
        }
    }

    /// Conditions scoped to one video codec (and optionally to containers)
    public struct VideoCodecRule: Sendable, Equatable {
        public var codec: String

        /// Containers the rule applies to; nil applies it everywhere
        public var containers: [String]?

        public var conditions: [VideoCodecCondition]

        public init(codec: String, containers: [String]? = nil, conditions: [VideoCodecCondition]) {
            self.codec = codec
            self.containers = containers
            self.conditions = conditions
        }
    }

    public var videoCodecRules: [VideoCodecRule]

    /// One subtitle format the engine (or the app around it) can handle,
    /// and how the server should deliver it
    public struct SubtitleRule: Sendable, Equatable {
        public enum Delivery: Sendable, Equatable {
            /// Rendered from the embedded track of a direct-played file
            case embed
            /// Fetched as a sidecar the app delivers itself
            case external
            /// Served as a text rendition in the HLS master playlist
            case hls
            /// Burned into the video server-side (forces a re-encode)
            case encode
        }

        public var format: String
        public var delivery: Delivery

        public init(format: String, delivery: Delivery) {
            self.format = format
            self.delivery = delivery
        }
    }

    public var subtitles: [SubtitleRule]

    /// What the engine accepts when the server must repackage or re-encode
    public struct TranscodingRule: Sendable, Equatable {
        public var containers: [String]
        public var videoCodecs: [String]
        public var audioCodecs: [String]
        public var minSegments: Int
        public var breaksOnNonKeyFrames: Bool

        public init(
            containers: [String],
            videoCodecs: [String],
            audioCodecs: [String],
            minSegments: Int,
            breaksOnNonKeyFrames: Bool,
        ) {
            self.containers = containers
            self.videoCodecs = videoCodecs
            self.audioCodecs = audioCodecs
            self.minSegments = minSegments
            self.breaksOnNonKeyFrames = breaksOnNonKeyFrames
        }
    }

    public var transcoding: TranscodingRule

    public init(
        name: String,
        maxStreamingBitrate: Int,
        directPlay: [DirectPlayRule],
        videoCodecRules: [VideoCodecRule],
        subtitles: [SubtitleRule],
        transcoding: TranscodingRule,
    ) {
        self.name = name
        self.maxStreamingBitrate = maxStreamingBitrate
        self.directPlay = directPlay
        self.videoCodecRules = videoCodecRules
        self.subtitles = subtitles
        self.transcoding = transcoding
    }
}

public extension PlaybackCapabilities {
    /// The declared video range types, read back out of the codec rules —
    /// the `videoRangeType` condition is the single stored source, so the
    /// PlaybackInfo negotiation (pipe-joined, in the derived profile) and
    /// the hand-built stream URL (comma-joined, below) can never disagree.
    var videoRangeTypes: [String] {
        for rule in videoCodecRules {
            for condition in rule.conditions where condition.property == .videoRangeType {
                return condition.value.split(separator: "|").map(String.init)
            }
        }
        return []
    }

    /// The range set as the codec-scoped `hevc-rangetype` stream option
    /// (comma-separated, the server's own TranscodingUrl serialization)
    var hevcRangeTypesParameter: String {
        videoRangeTypes.joined(separator: ",")
    }
}

import Foundation
import JellyfinAPI

// MARK: - Device Profile

//
// The device profile tells the server what the client can play natively,
// so PlaybackInfo can decide between direct play, remux, and transcode.
//
// It is DERIVED from the engine's `PlaybackCapabilities` declaration (#85)
// rather than hardcoded: every claim in the profile is a property of the
// engine that decodes the stream, so the engine owns the values and this
// builder owns only the translation into Jellyfin's wire schema.

extension JellyfinAPI.DeviceProfile {
    // Label deliberately not `from:` — that overloads Decodable's
    // `init(from: Decoder)` and makes call sites ambiguous
    init(capabilities: PlaybackCapabilities) {
        self.init(
            codecProfiles: capabilities.videoCodecRules.map { rule in
                JellyfinAPI.CodecProfile(
                    codec: rule.codec,
                    conditions: rule.conditions.map { condition in
                        JellyfinAPI.ProfileCondition(
                            condition: .init(from: condition.comparison),
                            isRequired: condition.isRequired,
                            property: .init(from: condition.property),
                            value: condition.value,
                        )
                    },
                    container: rule.containers?.joined(separator: ","),
                    type: .video,
                )
            },
            directPlayProfiles: capabilities.directPlay.map { rule in
                JellyfinAPI.DirectPlayProfile(
                    audioCodec: rule.audioCodecs.joined(separator: ","),
                    container: rule.containers.joined(separator: ","),
                    type: .video,
                    videoCodec: rule.videoCodecs.joined(separator: ","),
                )
            },
            name: capabilities.name,
            subtitleProfiles: capabilities.subtitles.map { rule in
                JellyfinAPI.SubtitleProfile(
                    format: rule.format,
                    method: .init(from: rule.delivery),
                )
            },
            transcodingProfiles: [
                JellyfinAPI.TranscodingProfile(
                    audioCodec: capabilities.transcoding.audioCodecs.joined(separator: ","),
                    isBreakOnNonKeyFrames: capabilities.transcoding.breaksOnNonKeyFrames,
                    container: capabilities.transcoding.containers.joined(separator: ","),
                    context: .streaming,
                    minSegments: capabilities.transcoding.minSegments,
                    protocol: .hls,
                    type: .video,
                    videoCodec: capabilities.transcoding.videoCodecs.joined(separator: ","),
                ),
            ],
        )
    }
}

private extension JellyfinAPI.ProfileConditionType {
    init(from comparison: PlaybackCapabilities.VideoCodecCondition.Comparison) {
        self = switch comparison {
        case .equalsAny: .equalsAny
        case .lessThanEqual: .lessThanEqual
        }
    }
}

private extension JellyfinAPI.ProfileConditionValue {
    init(from property: PlaybackCapabilities.VideoCodecCondition.Property) {
        self = switch property {
        case .videoCodecTag: .videoCodecTag
        case .videoRangeType: .videoRangeType
        case .videoBitDepth: .videoBitDepth
        case .videoProfile: .videoProfile
        }
    }
}

private extension JellyfinAPI.SubtitleDeliveryMethod {
    init(from delivery: PlaybackCapabilities.SubtitleRule.Delivery) {
        self = switch delivery {
        case .embed: .embed
        case .external: .external
        case .hls: .hls
        case .encode: .encode
        }
    }
}

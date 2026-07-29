@testable import JellyfinKit

extension PlaybackCapabilities {
    /// The AVFoundation engine's declaration, duplicated as a host-tier
    /// fixture: the real declaration lives in the Features package (on
    /// `AVFoundationPlayerEngine`), which the JellyfinKit host suite cannot
    /// import. A FeaturesTests suite pins the real declaration to these same
    /// values, so the two suites together cover the derivation chain.
    static let jellySharkAVFoundationFixture = PlaybackCapabilities(
        name: "Jelly Shark",
        maxStreamingBitrate: 120_000_000,
        directPlay: [
            PlaybackCapabilities.DirectPlayRule(
                containers: ["mp4", "m4v", "mov"],
                videoCodecs: ["hevc", "h264"],
                audioCodecs: ["aac", "ac3", "eac3", "flac", "alac"],
            ),
        ],
        videoCodecRules: [
            PlaybackCapabilities.VideoCodecRule(
                codec: "hevc",
                containers: ["mp4", "m4v", "mov"],
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoCodecTag,
                        comparison: .equalsAny,
                        value: "hvc1|dvh1",
                        isRequired: true,
                    ),
                ],
            ),
            PlaybackCapabilities.VideoCodecRule(
                codec: "hevc",
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoRangeType,
                        comparison: .equalsAny,
                        value: "SDR|HDR10|HLG|DOVIWithHDR10",
                        isRequired: false,
                    ),
                ],
            ),
            PlaybackCapabilities.VideoCodecRule(
                codec: "h264",
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoBitDepth,
                        comparison: .lessThanEqual,
                        value: "8",
                        isRequired: false,
                    ),
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoProfile,
                        comparison: .equalsAny,
                        value: "high|main|baseline|constrained baseline",
                        isRequired: false,
                    ),
                ],
            ),
        ],
        subtitles: [
            PlaybackCapabilities.SubtitleRule(format: "mov_text", delivery: .embed),
            PlaybackCapabilities.SubtitleRule(format: "vtt", delivery: .external),
            PlaybackCapabilities.SubtitleRule(format: "subrip", delivery: .external),
            PlaybackCapabilities.SubtitleRule(format: "vtt", delivery: .hls),
            PlaybackCapabilities.SubtitleRule(format: "subrip", delivery: .hls),
            PlaybackCapabilities.SubtitleRule(format: "ass", delivery: .encode),
            PlaybackCapabilities.SubtitleRule(format: "ssa", delivery: .encode),
            PlaybackCapabilities.SubtitleRule(format: "pgssub", delivery: .encode),
            PlaybackCapabilities.SubtitleRule(format: "dvdsub", delivery: .encode),
        ],
        transcoding: PlaybackCapabilities.TranscodingRule(
            containers: ["mp4", "ts"],
            videoCodecs: ["hevc", "h264"],
            audioCodecs: ["aac", "ac3", "eac3"],
            minSegments: 2,
            breaksOnNonKeyFrames: true,
        ),
    )
}

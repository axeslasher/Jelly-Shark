import Foundation
import JellyfinAPI

// MARK: - Device Profile

//
// The device profile tells the server what this client can play natively,
// so PlaybackInfo can decide between direct play, remux, and transcode.

extension JellyfinClient {
    /// Streaming bitrate ceiling declared to the server (120 Mbps).
    ///
    /// PlaybackInfo requests MUST carry this: when the field is omitted the
    /// server falls back to a low default cap and reports
    /// `SupportsDirectPlay=false` for most real-world files (observed
    /// cutoff ~2.5 Mbps against Jellyfin 10.10). 120 Mbps comfortably covers
    /// 4K remuxes on a LAN while still letting the server transcode down for
    /// genuinely enormous sources.
    static let maxStreamingBitrate = 120_000_000

    /// Capabilities profile for Apple TV / Vision Pro playback via AVPlayer
    static var deviceProfile: JellyfinAPI.DeviceProfile {
        JellyfinAPI.DeviceProfile(
            // Conditions a source's video stream must meet for the blanket
            // codec claims in directPlayProfiles to hold. Without these the
            // server offers direct play for variants AVFoundation can't
            // decode. Mirrors Swiftfin's AVKit conditions.
            codecProfiles: [
                // AVFoundation only decodes HEVC in mp4/m4v/mov when the
                // sample entry is tagged hvc1 (or Dolby Vision's dvh1).
                // ffmpeg tags hev1 by default, which plays audio over a
                // black screen — route those through HLS instead.
                JellyfinAPI.CodecProfile(
                    codec: "hevc",
                    conditions: [
                        JellyfinAPI.ProfileCondition(
                            condition: .equalsAny,
                            isRequired: true,
                            property: .videoCodecTag,
                            value: "hvc1|dvh1",
                        ),
                    ],
                    type: .video,
                ),
                // No Apple hardware decodes 10-bit H.264 (Hi10P), and only
                // the mainstream profiles are supported. isRequired stays
                // false so sources with unprobed depth/profile aren't
                // needlessly rejected.
                JellyfinAPI.CodecProfile(
                    codec: "h264",
                    conditions: [
                        JellyfinAPI.ProfileCondition(
                            condition: .lessThanEqual,
                            isRequired: false,
                            property: .videoBitDepth,
                            value: "8",
                        ),
                        JellyfinAPI.ProfileCondition(
                            condition: .equalsAny,
                            isRequired: false,
                            property: .videoProfile,
                            value: "high|main|baseline|constrained baseline",
                        ),
                    ],
                    type: .video,
                ),
            ],
            directPlayProfiles: [
                JellyfinAPI.DirectPlayProfile(
                    audioCodec: "aac,ac3,eac3,flac,alac",
                    container: "mp4,m4v,mov",
                    type: .video,
                    videoCodec: "hevc,h264",
                ),
            ],
            name: "Jelly Shark",
            subtitleProfiles: [
                // AVPlayer renders embedded tx3g (mov_text) natively; without
                // this declaration the server refuses to direct play any
                // mp4/mov that merely CONTAINS such a track
                JellyfinAPI.SubtitleProfile(format: "mov_text", method: .embed),
                // External keeps SupportsDirectPlay=true for files that have
                // text sidecars: without it the server reports
                // SubtitleCodecNotSupported and forces a transcode even when
                // no subtitle was requested. Selected text subs are still
                // delivered as HLS renditions via SubtitleMethod on the
                // stream URL.
                JellyfinAPI.SubtitleProfile(format: "vtt", method: .external),
                JellyfinAPI.SubtitleProfile(format: "subrip", method: .external),
                JellyfinAPI.SubtitleProfile(format: "vtt", method: .hls),
                JellyfinAPI.SubtitleProfile(format: "subrip", method: .hls),
                JellyfinAPI.SubtitleProfile(format: "ass", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "ssa", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "pgssub", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "dvdsub", method: .encode),
            ],
            transcodingProfiles: [
                // ts to match StreamURLBuilder's SegmentContainer — see the
                // comment there for why fMP4 breaks HLS subtitle timing
                JellyfinAPI.TranscodingProfile(
                    audioCodec: "aac,ac3,eac3",
                    isBreakOnNonKeyFrames: true,
                    container: "ts",
                    context: .streaming,
                    minSegments: 2,
                    protocol: .hls,
                    type: .video,
                    videoCodec: "hevc,h264",
                ),
            ],
        )
    }
}

import Foundation
import JellyfinAPI

// MARK: - Device Profile
//
// The device profile tells the server what this client can play natively,
// so PlaybackInfo can decide between direct play, remux, and transcode.

extension JellyfinClient {
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
                            value: "hvc1|dvh1"
                        ),
                    ],
                    type: .video
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
                            value: "8"
                        ),
                        JellyfinAPI.ProfileCondition(
                            condition: .equalsAny,
                            isRequired: false,
                            property: .videoProfile,
                            value: "high|main|baseline|constrained baseline"
                        ),
                    ],
                    type: .video
                ),
            ],
            directPlayProfiles: [
                JellyfinAPI.DirectPlayProfile(
                    audioCodec: "aac,ac3,eac3,flac,alac",
                    container: "mp4,m4v,mov",
                    type: .video,
                    videoCodec: "hevc,h264"
                ),
            ],
            name: "Jelly Shark",
            subtitleProfiles: [
                JellyfinAPI.SubtitleProfile(format: "vtt", method: .hls),
                JellyfinAPI.SubtitleProfile(format: "subrip", method: .hls),
                JellyfinAPI.SubtitleProfile(format: "ass", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "ssa", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "pgssub", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "dvdsub", method: .encode),
            ],
            transcodingProfiles: [
                JellyfinAPI.TranscodingProfile(
                    audioCodec: "aac,ac3,eac3",
                    isBreakOnNonKeyFrames: true,
                    container: "mp4",
                    context: .streaming,
                    minSegments: 2,
                    protocol: .hls,
                    type: .video,
                    videoCodec: "hevc,h264"
                ),
            ]
        )
    }
}

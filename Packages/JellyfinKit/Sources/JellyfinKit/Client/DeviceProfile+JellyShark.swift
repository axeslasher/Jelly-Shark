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

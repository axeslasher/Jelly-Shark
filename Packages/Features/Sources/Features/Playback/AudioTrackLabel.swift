import Foundation
import JellyfinKit

extension MediaStreamInfo {
    /// Menu/picker copy for an audio track, with a stable fallback chain so
    /// every audio surface labels the same stream identically. Used by both
    /// the tvOS transport-bar menu and the visionOS track-picker panel — the
    /// burn-in subtitle equivalent is `BurnInSubtitleLabel`.
    var audioTrackTitle: String {
        displayTitle ?? language ?? "Track \(index)"
    }
}

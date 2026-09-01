import Foundation
import JellyfinKit
import Observation

/// User preferences for playback behavior, UserDefaults-backed like
/// `HomePreferences` (which documents the pattern: RootView owns an instance
/// and injects it into the environment; no singleton, so tests and previews
/// can construct their own over a scratch defaults suite).
@MainActor
@Observable
public final class PlaybackPreferences {
    /// Ask which version to play on every launch of a multi-version item
    /// (#147 mode 2). Off (the default) offers versions through a long-press
    /// menu on the Play control instead, and a plain press plays the server
    /// default. Single-version items never ask either way.
    public var asksVersionBeforePlaying: Bool {
        didSet {
            defaults.set(asksVersionBeforePlaying, forKey: Self.asksVersionKey)
        }
    }

    /// The ceiling the app asks the server for (#168). `.maximum` — the
    /// default — leaves the engine's declared 120 Mbps ceiling in place, so
    /// an untouched install negotiates exactly as it did before this setting
    /// existed and direct play is still offered for the same files.
    ///
    /// Read once per playback launch: Settings is unreachable during
    /// playback, so a change takes effect on the next title started rather
    /// than rebuilding a running session.
    public var streamingQuality: StreamingQualityTier {
        didSet {
            defaults.set(streamingQuality.rawValue, forKey: Self.streamingQualityKey)
        }
    }

    private let defaults: UserDefaults
    private static let asksVersionKey = "asksVersionBeforePlaying"
    private static let streamingQualityKey = "streamingQualityBitrate"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        asksVersionBeforePlaying = defaults.bool(forKey: Self.asksVersionKey)
        // `integer(forKey:)` reads absence as 0, which is `.maximum` — the
        // default this setting must have. A stored value the current tier
        // list no longer names (an older or newer build's) falls back there
        // too, rather than being remapped to some other speed.
        streamingQuality = StreamingQualityTier(
            rawValue: defaults.integer(forKey: Self.streamingQualityKey),
        ) ?? .maximum
    }
}

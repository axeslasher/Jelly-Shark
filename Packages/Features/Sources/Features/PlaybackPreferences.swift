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
        // `object(forKey:)` rather than `integer(forKey:)`: absence has to
        // stay distinguishable from an explicit 0 (`.maximum`). Both resolve
        // to `.maximum` today, but reading them as the same value would let a
        // future change of default silently migrate the viewers who picked
        // Maximum on purpose. A stored value the current tier list no longer
        // names (an older or newer build's) falls back to the default too,
        // rather than being remapped to some other speed.
        streamingQuality = (defaults.object(forKey: Self.streamingQualityKey) as? Int)
            .flatMap(StreamingQualityTier.init(rawValue:)) ?? .maximum
    }
}

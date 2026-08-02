import Foundation
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

    private let defaults: UserDefaults
    private static let asksVersionKey = "asksVersionBeforePlaying"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        asksVersionBeforePlaying = defaults.bool(forKey: Self.asksVersionKey)
    }
}

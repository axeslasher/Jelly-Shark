import Foundation
import Observation

/// User preferences for the Home screen layout, UserDefaults-backed like
/// `ThemeManager`'s theme choice. Lives in Features (not DesignSystem)
/// because it's browsing business logic, not visual language. RootView owns
/// an instance and injects it into the environment; no singleton, so tests
/// and previews can construct their own over a scratch defaults suite.
@MainActor
@Observable
public final class HomePreferences {
    /// Fold Next Up into Continue Watching as one lane ordered by
    /// last-engagement recency (the default). Off restores the separate
    /// Continue Watching and Next Up shelves.
    public var mergesContinueWatching: Bool {
        didSet {
            defaults.set(mergesContinueWatching, forKey: Self.mergesKey)
        }
    }

    /// Show Home's affinity shelves — the rows derived from what you have
    /// played and favorited (#86). Off removes every affinity row and stops
    /// its fetches entirely, rather than hiding a result it still paid for.
    public var showsDiscoveryShelves: Bool {
        didSet {
            defaults.set(showsDiscoveryShelves, forKey: Self.discoveryKey)
        }
    }

    private let defaults: UserDefaults
    private static let mergesKey = "mergesContinueWatching"
    private static let discoveryKey = "showsDiscoveryShelves"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // object(forKey:), not bool(forKey:): absence must default to true.
        mergesContinueWatching = defaults.object(forKey: Self.mergesKey) as? Bool ?? true
        showsDiscoveryShelves = defaults.object(forKey: Self.discoveryKey) as? Bool ?? true
    }
}

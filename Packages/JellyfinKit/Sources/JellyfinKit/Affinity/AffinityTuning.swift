import Foundation

/// Every tunable the affinity engine reads, in one place.
///
/// These are feel values, not derived constants. Appearance and ranking are
/// invisible to every suite here, so the way they get tuned is bisection:
/// flip one, build, read pass/fail on device (CLAUDE.md § What tests cannot
/// verify). Starting values come from the design doc's § 5 and § 8.
public enum AffinityTuning {
    // MARK: Signal weights

    /// A favorite outweighs a play because it is an explicit, durable
    /// statement rather than an implicit one — and unlike a play it never
    /// decays.
    public static let favoriteWeight = 3.0

    /// How long it takes a play's weight to halve. A run of films last week
    /// should outrank an equal run from eight months ago.
    public static let halfLifeDays = 30.0

    // MARK: Qualification

    /// Distinct contributing sources a bucket needs before it can mint a
    /// shelf. Stops one horror film from minting a horror shelf.
    public static let minContributors = 3

    /// How over-represented a bucket must be versus its share of the
    /// library. Stops "Drama" — half of many libraries — winning every time.
    public static let minRatio = 1.5

    // MARK: Selection

    /// Bias on the similar-items shelf, relative to the bucket score of its
    /// seed. 1.0 means it competes at face value.
    public static let similarShelfWeight = 1.0

    /// A shelf with fewer items than this after de-overlapping is dropped.
    public static let minShelfItems = 5

    /// Hard cap on affinity rows. This is what keeps Home's row budget
    /// bounded (#129 is not gating, and this cap is why).
    public static let maxShelves = 3

    /// Credit kinds pulled out of items. Cast lists run to dozens of actors
    /// and would swamp the person population; authorship is also the signal
    /// the archetype names. Favoriting a person unlocks their credits
    /// regardless of kind — see `AffinityExtractor`.
    public static let eligiblePersonKinds: Set<String> = ["Director", "Writer"]

    // MARK: Fetch windows

    /// Played movies fetched for the signal set.
    public static let playedMovieLimit = 60

    /// Played episodes fetched. Larger than the movie window because these
    /// collapse: 120 episodes typically span ~10 series. Fetched separately
    /// from movies so a binge cannot crowd films out of a shared window.
    public static let playedEpisodeLimit = 120

    /// Favorites fetched. Jellyfin exposes no "date favorited" field, so the
    /// window is alphabetical (see the client method) — stable rather than
    /// arbitrary, which is what the fingerprint needs.
    public static let favoritedItemLimit = 100

    /// Items per affinity shelf.
    public static let shelfItemLimit = 20

    // MARK: Freshness

    /// How long a probed `librarySize` is reused before re-probing.
    public static let stampTTL: TimeInterval = 60 * 60

    /// How long a bucket denominator is reused. Also invalidated outright
    /// whenever the library stamp moves.
    public static let denominatorTTL: TimeInterval = 7 * 24 * 60 * 60
}

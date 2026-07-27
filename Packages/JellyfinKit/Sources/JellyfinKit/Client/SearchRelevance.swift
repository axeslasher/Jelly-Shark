import Foundation

/// The ordering policy for search results, applied client-side after the fetch.
///
/// **Why this exists at all.** Jellyfin offers no relevance sort. `ItemSortBy`
/// has no such case, so `/Items?searchTerm=` can only be ordered by name, date,
/// rating and friends — and asking for *no* sort yields whatever order the
/// database happens to return, which is undefined rather than relevant. The
/// server's `/Search/Hints` endpoint is no better on the versions this app
/// supports: through 10.10.x its `SearchEngine` builds its internal query with
/// `OrderBy = [(SortName, Ascending)]`, so hints come back alphabetical too,
/// minus the fields (overview, genres, user data) a `BaseItemDto` carries.
/// Adopting it would have cost a second adapter and bought nothing.
///
/// **The ordering, stated.** Results are grouped into match tiers — exact,
/// then whole-title prefix, then word prefix, then substring — and ordered by
/// tier, best first. Within a tier the server's own order survives untouched,
/// which is `SortName` ascending: alphabetical, so ties are stable and
/// predictable rather than arbitrary.
///
/// The tiers deliberately mirror Jellyfin's own: the server grew a scoring
/// search provider after 10.10 (`SqlSearchProvider`, exact 100 / prefix 80 /
/// word-prefix 75 / contains 50, tie-broken for determinism). Matching its
/// ladder means this client's ordering does not disagree with the server's the
/// day that provider ships in a release we can rely on.
enum SearchRelevance {
    /// How closely a title matched the query. Declaration order is rank order,
    /// best first — the raw values are what the sort compares.
    enum MatchTier: Int, Comparable {
        /// The whole title is the query ("batman" → *Batman*).
        case exact = 0
        /// The title starts with the query ("batman" → *Batman Begins*).
        case prefix = 1
        /// A later word starts with the query ("batman" → *The Batman*).
        case wordPrefix = 2
        /// The query appears mid-word ("man" → *Batman*).
        case contains = 3
        /// No match in either title. The server matched on something else, or
        /// on a form this normalisation does not reproduce; such items sort
        /// last rather than being dropped, because the server included them.
        case none = 4

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// How many candidates to fetch per result the caller will show.
    ///
    /// The server can only truncate its result set alphabetically, so fetching
    /// exactly what the caller asked for would let the alphabet decide which
    /// matches ranking ever sees — the exact match for "star" would be cut
    /// somewhere in *Star Trek* before it could be promoted. A wider window
    /// makes the cap a ranking decision instead of an alphabetical one.
    static let fetchWindowMultiplier = 4

    /// Ceiling on the fetch window, to bound the payload of a query that
    /// matches half the library. Jellyfin's own search provider defaults to a
    /// 100-candidate pool; twice that is generous for a shelf of 25.
    static let maxFetchWindow = 200

    /// The number of items to request from the server for a caller that wants
    /// `limit` results back. `nil` in, `nil` out — an unlimited fetch needs no
    /// window.
    static func fetchWindow(for limit: Int?) -> Int? {
        guard let limit else { return nil }
        return min(limit * fetchWindowMultiplier, maxFetchWindow)
    }

    /// Order `items` by match quality against `query`, best first, preserving
    /// the incoming order within each tier.
    static func ranked(_ items: [MediaItem], matching query: String) -> [MediaItem] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return items }

        // Sorting the (tier, position) pairs rather than the items keeps this
        // stable: Swift's sort is not, and the incoming order is meaningful
        // (it is the server's alphabetical tie-break).
        return items.enumerated()
            .map { (tier: tier(for: $0.element, normalizedQuery: normalizedQuery), offset: $0.offset) }
            .sorted { ($0.tier, $0.offset) < ($1.tier, $1.offset) }
            .map { items[$0.offset] }
    }

    /// The best tier either of an item's titles achieves. The server matches on
    /// `Name` *or* `OriginalTitle`, so ranking has to look at both or a title
    /// matched only by its original name would sink to the bottom.
    static func tier(for item: MediaItem, normalizedQuery: String) -> MatchTier {
        min(
            tier(title: item.name, normalizedQuery: normalizedQuery),
            item.originalTitle.map { tier(title: $0, normalizedQuery: normalizedQuery) } ?? .none,
        )
    }

    /// The tier one title achieves against an already-normalised query.
    static func tier(title: String, normalizedQuery: String) -> MatchTier {
        let title = normalized(title)
        guard !title.isEmpty, !normalizedQuery.isEmpty else { return .none }

        if title == normalizedQuery {
            return .exact
        }
        if title.hasPrefix(normalizedQuery) {
            return .prefix
        }
        guard title.range(of: normalizedQuery) != nil else { return .none }

        // Walk every occurrence: any one of them starting a word earns the
        // word-prefix tier, even if an earlier occurrence sat mid-word.
        var searchStart = title.startIndex
        while let match = title.range(of: normalizedQuery, range: searchStart ..< title.endIndex) {
            if match.lowerBound > title.startIndex {
                let preceding = title[title.index(before: match.lowerBound)]
                if !preceding.isLetter, !preceding.isNumber {
                    return .wordPrefix
                }
            }
            searchStart = title.index(after: match.lowerBound)
        }
        return .contains
    }

    /// Case- and diacritic-insensitive, trimmed — the comparable form of a
    /// title or a query. Approximates the server's `CleanName`, which is how
    /// the match was made in the first place.
    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

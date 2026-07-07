import Foundation
import JellyfinAPI

// MARK: - Sorting

/// How a library grid is sorted
public enum LibrarySort: String, CaseIterable, Sendable, Hashable {
    case name
    case releaseDate
    case dateAdded
    case communityRating
    case criticRating
}

/// Sort direction for a library grid
public enum LibrarySortDirection: String, Sendable, Hashable {
    case ascending
    case descending
}

// MARK: - Filters

/// Watched-state filter; mutually exclusive by construction
public enum WatchedFilter: String, CaseIterable, Sendable, Hashable {
    case any
    case unplayed
    case played
}

/// Everything the user can dial in on a library grid: sort plus filters.
/// Multi-select filters are ORed within a field and ANDed across fields,
/// matching the server's semantics.
public struct LibraryQuery: Sendable, Equatable {
    public var sort: LibrarySort
    public var direction: LibrarySortDirection
    public var genres: Set<String>
    /// Decade start years, e.g. 1980 for "the 1980s"
    public var decades: Set<Int>
    public var watched: WatchedFilter
    public var favoritesOnly: Bool
    public var officialRatings: Set<String>

    public init(
        sort: LibrarySort = .name,
        direction: LibrarySortDirection = .ascending,
        genres: Set<String> = [],
        decades: Set<Int> = [],
        watched: WatchedFilter = .any,
        favoritesOnly: Bool = false,
        officialRatings: Set<String> = []
    ) {
        self.sort = sort
        self.direction = direction
        self.genres = genres
        self.decades = decades
        self.watched = watched
        self.favoritesOnly = favoritesOnly
        self.officialRatings = officialRatings
    }

    /// True when any filter differs from the default (sort is not a filter)
    public var isFiltering: Bool {
        self != LibraryQuery(sort: sort, direction: direction)
    }

    /// Decades expanded to concrete years for the server's `years` parameter
    public var expandedYears: [Int]? {
        decades.isEmpty ? nil : decades.sorted().flatMap { $0..<($0 + 10) }
    }

    /// The same query with all filters cleared, keeping sort and direction
    public var withFiltersCleared: LibraryQuery {
        LibraryQuery(sort: sort, direction: direction)
    }
}

// MARK: - Results

/// One page of a library fetch
public struct MediaItemPage: Sendable {
    public let items: [MediaItem]
    public let startIndex: Int
    public let totalRecordCount: Int?

    public init(items: [MediaItem], startIndex: Int, totalRecordCount: Int?) {
        self.items = items
        self.startIndex = startIndex
        self.totalRecordCount = totalRecordCount
    }

    public var hasMore: Bool {
        guard let total = totalRecordCount else { return !items.isEmpty }
        return startIndex + items.count < total
    }
}

/// Filter values actually present in a library (from GET /Items/Filters)
public struct LibraryFilterOptions: Sendable, Equatable {
    public let genres: [String]
    public let officialRatings: [String]
    public let years: [Int]

    public init(genres: [String], officialRatings: [String], years: [Int]) {
        self.genres = genres
        self.officialRatings = officialRatings
        self.years = years
    }

    /// Distinct decade start years present in the library, newest first
    public var decades: [Int] {
        Array(Set(years.map { $0 / 10 * 10 })).sorted(by: >)
    }

    public static let empty = LibraryFilterOptions(genres: [], officialRatings: [], years: [])
}

// MARK: - SDK Mapping

extension LibrarySort {
    /// Server sort keys; secondary keys make ties deterministic
    var sdkSortBy: [JellyfinAPI.ItemSortBy] {
        switch self {
        case .name: return [.sortName]
        case .releaseDate: return [.premiereDate, .productionYear, .sortName]
        case .dateAdded: return [.dateCreated, .sortName]
        case .communityRating: return [.communityRating, .sortName]
        case .criticRating: return [.criticRating, .sortName]
        }
    }
}

extension LibrarySortDirection {
    var sdkSortOrder: JellyfinAPI.SortOrder {
        switch self {
        case .ascending: return .ascending
        case .descending: return .descending
        }
    }
}

extension LibraryQuery {
    var sdkFilters: [JellyfinAPI.ItemFilter]? {
        var filters: [JellyfinAPI.ItemFilter] = []
        switch watched {
        case .unplayed: filters.append(.isUnplayed)
        case .played: filters.append(.isPlayed)
        case .any: break
        }
        if favoritesOnly {
            filters.append(.isFavorite)
        }
        return filters.isEmpty ? nil : filters
    }
}

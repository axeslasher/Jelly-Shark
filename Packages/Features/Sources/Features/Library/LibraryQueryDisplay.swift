import Foundation
import JellyfinKit

/// Display language for library sort and filter state: menu phrases and the
/// grid's dynamic title.

extension LibrarySort {
    /// A plain-language phrase for sorting in the given direction, shown in
    /// place of ascending/descending jargon ("A to Z", "Fan Favorites", ...)
    func phrase(for direction: LibrarySortDirection) -> String {
        switch (self, direction) {
        case (.name, .ascending): return "A to Z"
        case (.name, .descending): return "Z to A"
        case (.releaseDate, .descending): return "Newest First"
        case (.releaseDate, .ascending): return "Oldest First"
        case (.dateAdded, .descending): return "Newest Arrivals"
        case (.dateAdded, .ascending): return "Oldest Arrivals"
        case (.communityRating, .descending): return "Fan Favorites"
        case (.communityRating, .ascending): return "Fan Scorned"
        case (.criticRating, .descending): return "Critically Acclaimed"
        case (.criticRating, .ascending): return "Critically Panned"
        }
    }

    /// The direction people expect when first picking this sort
    var defaultDirection: LibrarySortDirection {
        self == .name ? .ascending : .descending
    }
}

extension WatchedFilter {
    var displayName: String {
        switch self {
        case .any: return "Any"
        case .unplayed: return "Unwatched"
        case .played: return "Watched"
        }
    }
}

extension LibraryQuery {
    /// A headline describing the current filter selections:
    /// "All Movies", "Horror Movies from the 1980s",
    /// "Unwatched Favorite Westerns rated R"
    func displayTitle(libraryName: String) -> String {
        guard isFiltering else { return "All \(libraryName)" }

        var words: [String] = []

        switch watched {
        case .unplayed: words.append("Unwatched")
        case .played: words.append("Watched")
        case .any: break
        }

        if favoritesOnly {
            words.append("Favorite")
        }

        if !genres.isEmpty {
            words.append(Self.shortList(genres.sorted()))
        }

        words.append(libraryName)

        if !decades.isEmpty {
            let names = decades.sorted().map { "\($0.formatted(.number.grouping(.never)))s" }
            words.append("from the \(Self.shortList(names))")
        }

        if !officialRatings.isEmpty {
            words.append("rated \(Self.shortList(officialRatings.sorted()))")
        }

        return words.joined(separator: " ")
    }

    /// "Horror", "Horror & Comedy", or "Horror, Comedy & More"
    private static func shortList(_ values: [String]) -> String {
        switch values.count {
        case 1: return values[0]
        case 2: return "\(values[0]) & \(values[1])"
        default: return "\(values[0]), \(values[1]) & More"
        }
    }
}

import Foundation
import JellyfinKit

// Display language for library sort and filter state: menu phrases and the
// grid's dynamic title.

extension LibrarySort {
    /// A plain-language phrase for sorting in the given direction, shown in
    /// place of ascending/descending jargon ("A to Z", "Fan Favorites", ...)
    func phrase(for direction: LibrarySortDirection) -> String {
        switch (self, direction) {
        case (.name, .ascending): "A to Z"
        case (.name, .descending): "Z to A"
        case (.releaseDate, .descending): "Newest First"
        case (.releaseDate, .ascending): "Oldest First"
        case (.dateAdded, .descending): "Newest Arrivals"
        case (.dateAdded, .ascending): "Oldest Arrivals"
        case (.communityRating, .descending): "Fan Favorites"
        case (.communityRating, .ascending): "Fan Scorned"
        case (.criticRating, .descending): "Critically Acclaimed"
        case (.criticRating, .ascending): "Critically Panned"
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
        case .any: "Any"
        case .unplayed: "Unwatched"
        case .played: "Watched"
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
        case 1: values[0]
        case 2: "\(values[0]) & \(values[1])"
        default: "\(values[0]), \(values[1]) & More"
        }
    }
}

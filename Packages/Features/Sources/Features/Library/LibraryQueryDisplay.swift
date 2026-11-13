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
    var displayName: LocalizedStringResource {
        switch self {
        case .any: LocalizedStringResource("library.filter.watched.any", bundle: #bundle, comment: "Watched-status filter option that shows every item.")
        case .unplayed: LocalizedStringResource("library.filter.watched.unplayed", bundle: #bundle, comment: "Watched-status filter option that shows only items not yet watched.")
        case .played: LocalizedStringResource("library.filter.watched.played", bundle: #bundle, comment: "Watched-status filter option that shows only items already watched.")
        }
    }
}

extension LibraryQuery {
    /// A headline describing the current filter selections:
    /// "All Movies", "Horror Movies from the 1980s",
    /// "Unwatched Favorite Westerns rated R"
    ///
    /// Each combination of filters is one sentence in the catalog, so every
    /// language orders its own words; only the lists and the library's name
    /// are filled in.
    func displayTitle(libraryName: String) -> String {
        let library = libraryName
        let genreList = genres.isEmpty ? nil : Self.shortList(genres.sorted())
        let decadeList = decades.isEmpty ? nil : Self.shortList(decades.sorted().map(Self.decadeName))
        let ratingList = officialRatings.isEmpty ? nil : Self.shortList(officialRatings.sorted())

        switch (watched, favoritesOnly, genreList, decadeList, ratingList) {
        case (.any, false, nil, nil, nil):
            return String(localized: "library.headline.all \(library)", bundle: #bundle, comment: "Heading over an unfiltered library. %@ is the library’s name from the server, such as “Movies”.")
        case let (.any, false, nil, nil, r?):
            return String(localized: "library.headline.rating \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.any, false, nil, d?, nil):
            return String(localized: "library.headline.decade \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by decade. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.any, false, nil, d?, r?):
            return String(localized: "library.headline.decade.rating \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by decade and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.any, false, g?, nil, nil):
            return String(localized: "library.headline.genre \(g) \(library)", bundle: #bundle, comment: "Heading over a library filtered by genre. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”.")
        case let (.any, false, g?, nil, r?):
            return String(localized: "library.headline.genre.rating \(g) \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by genre and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.any, false, g?, d?, nil):
            return String(localized: "library.headline.genre.decade \(g) \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by genre and decade. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.any, false, g?, d?, r?):
            return String(localized: "library.headline.genre.decade.rating \(g) \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by genre, decade and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”. %4$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case (.any, true, nil, nil, nil):
            return String(localized: "library.headline.favorite \(library)", bundle: #bundle, comment: "Heading over a library filtered by favorites only. %1$@ is the library’s name from the server, such as “Movies”.")
        case let (.any, true, nil, nil, r?):
            return String(localized: "library.headline.favorite.rating \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by favorites only and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.any, true, nil, d?, nil):
            return String(localized: "library.headline.favorite.decade \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by favorites only and decade. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.any, true, nil, d?, r?):
            return String(localized: "library.headline.favorite.decade.rating \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by favorites only, decade and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.any, true, g?, nil, nil):
            return String(localized: "library.headline.favorite.genre \(g) \(library)", bundle: #bundle, comment: "Heading over a library filtered by favorites only and genre. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”.")
        case let (.any, true, g?, nil, r?):
            return String(localized: "library.headline.favorite.genre.rating \(g) \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by favorites only, genre and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.any, true, g?, d?, nil):
            return String(localized: "library.headline.favorite.genre.decade \(g) \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by favorites only, genre and decade. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.any, true, g?, d?, r?):
            return String(localized: "library.headline.favorite.genre.decade.rating \(g) \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by favorites only, genre, decade and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”. %4$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case (.unplayed, false, nil, nil, nil):
            return String(localized: "library.headline.unwatched \(library)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only. %1$@ is the library’s name from the server, such as “Movies”.")
        case let (.unplayed, false, nil, nil, r?):
            return String(localized: "library.headline.unwatched.rating \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.unplayed, false, nil, d?, nil):
            return String(localized: "library.headline.unwatched.decade \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only and decade. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.unplayed, false, nil, d?, r?):
            return String(localized: "library.headline.unwatched.decade.rating \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, decade and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.unplayed, false, g?, nil, nil):
            return String(localized: "library.headline.unwatched.genre \(g) \(library)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only and genre. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”.")
        case let (.unplayed, false, g?, nil, r?):
            return String(localized: "library.headline.unwatched.genre.rating \(g) \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, genre and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.unplayed, false, g?, d?, nil):
            return String(localized: "library.headline.unwatched.genre.decade \(g) \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, genre and decade. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.unplayed, false, g?, d?, r?):
            return String(localized: "library.headline.unwatched.genre.decade.rating \(g) \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, genre, decade and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”. %4$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case (.unplayed, true, nil, nil, nil):
            return String(localized: "library.headline.unwatched.favorite \(library)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only and favorites only. %1$@ is the library’s name from the server, such as “Movies”.")
        case let (.unplayed, true, nil, nil, r?):
            return String(localized: "library.headline.unwatched.favorite.rating \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.unplayed, true, nil, d?, nil):
            return String(localized: "library.headline.unwatched.favorite.decade \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only and decade. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.unplayed, true, nil, d?, r?):
            return String(localized: "library.headline.unwatched.favorite.decade.rating \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only, decade and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.unplayed, true, g?, nil, nil):
            return String(localized: "library.headline.unwatched.favorite.genre \(g) \(library)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only and genre. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”.")
        case let (.unplayed, true, g?, nil, r?):
            return String(localized: "library.headline.unwatched.favorite.genre.rating \(g) \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only, genre and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.unplayed, true, g?, d?, nil):
            return String(localized: "library.headline.unwatched.favorite.genre.decade \(g) \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only, genre and decade. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.unplayed, true, g?, d?, r?):
            return String(localized: "library.headline.unwatched.favorite.genre.decade.rating \(g) \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by unwatched only, favorites only, genre, decade and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”. %4$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case (.played, false, nil, nil, nil):
            return String(localized: "library.headline.watched \(library)", bundle: #bundle, comment: "Heading over a library filtered by watched only. %1$@ is the library’s name from the server, such as “Movies”.")
        case let (.played, false, nil, nil, r?):
            return String(localized: "library.headline.watched.rating \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.played, false, nil, d?, nil):
            return String(localized: "library.headline.watched.decade \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by watched only and decade. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.played, false, nil, d?, r?):
            return String(localized: "library.headline.watched.decade.rating \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, decade and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.played, false, g?, nil, nil):
            return String(localized: "library.headline.watched.genre \(g) \(library)", bundle: #bundle, comment: "Heading over a library filtered by watched only and genre. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”.")
        case let (.played, false, g?, nil, r?):
            return String(localized: "library.headline.watched.genre.rating \(g) \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, genre and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.played, false, g?, d?, nil):
            return String(localized: "library.headline.watched.genre.decade \(g) \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by watched only, genre and decade. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.played, false, g?, d?, r?):
            return String(localized: "library.headline.watched.genre.decade.rating \(g) \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, genre, decade and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”. %4$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case (.played, true, nil, nil, nil):
            return String(localized: "library.headline.watched.favorite \(library)", bundle: #bundle, comment: "Heading over a library filtered by watched only and favorites only. %1$@ is the library’s name from the server, such as “Movies”.")
        case let (.played, true, nil, nil, r?):
            return String(localized: "library.headline.watched.favorite.rating \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.played, true, nil, d?, nil):
            return String(localized: "library.headline.watched.favorite.decade \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only and decade. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.played, true, nil, d?, r?):
            return String(localized: "library.headline.watched.favorite.decade.rating \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only, decade and age rating. %1$@ is the library’s name from the server, such as “Movies”. %2$@ is the decades, such as “1980s” or “1980s & 1990s”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.played, true, g?, nil, nil):
            return String(localized: "library.headline.watched.favorite.genre \(g) \(library)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only and genre. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”.")
        case let (.played, true, g?, nil, r?):
            return String(localized: "library.headline.watched.favorite.genre.rating \(g) \(library) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only, genre and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the age ratings, such as “R” or “PG & PG-13”.")
        case let (.played, true, g?, d?, nil):
            return String(localized: "library.headline.watched.favorite.genre.decade \(g) \(library) \(d)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only, genre and decade. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”.")
        case let (.played, true, g?, d?, r?):
            return String(localized: "library.headline.watched.favorite.genre.decade.rating \(g) \(library) \(d) \(r)", bundle: #bundle, comment: "Heading over a library filtered by watched only, favorites only, genre, decade and age rating. %1$@ is the genres, such as “Horror” or “Horror & Comedy”. %2$@ is the library’s name from the server, such as “Movies”. %3$@ is the decades, such as “1980s” or “1980s & 1990s”. %4$@ is the age ratings, such as “R” or “PG & PG-13”.")
        }
    }

    /// "1980s"
    private static func decadeName(_ decade: Int) -> String {
        String(localized: "library.headline.decadeName \(decade.formatted(.number.grouping(.never)))", bundle: #bundle, comment: "One decade in a library heading. %@ is the decade’s first year, such as 1980.")
    }

    /// "Horror", "Horror & Comedy", or "Horror, Comedy & More". Two values
    /// use the locale’s short list style; more are cut to the first two.
    private static func shortList(_ values: [String]) -> String {
        switch values.count {
        case 1: values[0]
        case 2: values.formatted(.list(type: .and, width: .short))
        default: String(localized: "library.headline.listAndMore \(values[0]) \(values[1])", bundle: #bundle, comment: "A list cut short in a library heading, such as “Horror, Comedy & More”. %1$@ and %2$@ are the first two genres, decades or age ratings.")
        }
    }
}

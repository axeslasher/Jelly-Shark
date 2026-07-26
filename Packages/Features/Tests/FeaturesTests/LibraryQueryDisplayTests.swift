@testable import Features
import JellyfinKit
import Testing

@Suite("LibraryQuery display")
struct LibraryQueryDisplayTests {
    @Suite("Sort phrases")
    struct SortPhraseTests {
        @Test("Every sort reads as plain language in both directions")
        func phrases() {
            #expect(LibrarySort.name.phrase(for: .ascending) == "A to Z")
            #expect(LibrarySort.name.phrase(for: .descending) == "Z to A")
            #expect(LibrarySort.releaseDate.phrase(for: .descending) == "Newest First")
            #expect(LibrarySort.releaseDate.phrase(for: .ascending) == "Oldest First")
            #expect(LibrarySort.dateAdded.phrase(for: .descending) == "Newest Arrivals")
            #expect(LibrarySort.dateAdded.phrase(for: .ascending) == "Oldest Arrivals")
            #expect(LibrarySort.communityRating.phrase(for: .descending) == "Fan Favorites")
            #expect(LibrarySort.communityRating.phrase(for: .ascending) == "Fan Scorned")
            #expect(LibrarySort.criticRating.phrase(for: .descending) == "Critically Acclaimed")
            #expect(LibrarySort.criticRating.phrase(for: .ascending) == "Critically Panned")
        }

        @Test("Alphabetical defaults ascending; everything else descending")
        func defaultDirections() {
            #expect(LibrarySort.name.defaultDirection == .ascending)
            #expect(LibrarySort.releaseDate.defaultDirection == .descending)
            #expect(LibrarySort.dateAdded.defaultDirection == .descending)
            #expect(LibrarySort.communityRating.defaultDirection == .descending)
            #expect(LibrarySort.criticRating.defaultDirection == .descending)
        }
    }

    @Suite("Display title")
    struct DisplayTitleTests {
        @Test("No filters reads as the whole library")
        func unfiltered() {
            #expect(LibraryQuery().displayTitle(libraryName: "Movies") == "All Movies")
        }

        @Test("Sort alone keeps the unfiltered title")
        func sortOnly() {
            let query = LibraryQuery(sort: .communityRating, direction: .descending)
            #expect(query.displayTitle(libraryName: "Movies") == "All Movies")
        }

        @Test("A genre and a decade compose a headline")
        func genreAndDecade() {
            let query = LibraryQuery(genres: ["Horror"], decades: [1980])
            #expect(query.displayTitle(libraryName: "Movies") == "Horror Movies from the 1980s")
        }

        @Test("Pairs join with an ampersand")
        func pairs() {
            let query = LibraryQuery(genres: ["Horror", "Comedy"], decades: [1990, 1980])
            #expect(
                query.displayTitle(libraryName: "Movies")
                    == "Comedy & Horror Movies from the 1980s & 1990s",
            )
        }

        @Test("Three or more values truncate to the first two & More")
        func truncation() {
            let query = LibraryQuery(genres: ["Horror", "Comedy", "Drama", "Action"])
            #expect(query.displayTitle(libraryName: "Movies") == "Action, Comedy & More Movies")
        }

        @Test("Watched state, favorites, and ratings all read in order")
        func fullHouse() {
            let query = LibraryQuery(
                genres: ["Western"],
                watched: .unplayed,
                favoritesOnly: true,
                officialRatings: ["R"],
            )
            #expect(
                query.displayTitle(libraryName: "Movies")
                    == "Unwatched Favorite Western Movies rated R",
            )
        }

        @Test("Decade names never pick up grouping separators")
        func decadeFormatting() {
            let query = LibraryQuery(decades: [2020])
            #expect(query.displayTitle(libraryName: "Shows") == "Shows from the 2020s")
        }
    }

    @Suite("Active filter summary")
    struct ActiveFilterSummaryTests {
        @Test("Nothing filtering summarises to nothing")
        func unfiltered() {
            #expect(LibraryQuery().activeFilterSummary == "")
        }

        @Test("Sort is not a filter")
        func sortOnly() {
            let query = LibraryQuery(sort: .communityRating, direction: .descending)
            #expect(query.activeFilterSummary == "")
        }

        @Test("The library scope is not a filter")
        func libraryScopeOnly() {
            let query = LibraryQuery(
                library: Library(id: "lib-1", name: "Films", collectionType: .movies),
            )
            #expect(query.activeFilterSummary == "")
        }

        @Test("A single genre reads as itself")
        func singleGenre() {
            #expect(LibraryQuery(genres: ["Anime"]).activeFilterSummary == "Anime")
        }

        @Test("The library scope never joins the summary")
        func libraryScopeExcluded() {
            let query = LibraryQuery(
                library: Library(id: "lib-1", name: "Films", collectionType: .movies),
                genres: ["Anime"],
            )
            #expect(query.activeFilterSummary == "Anime")
        }

        @Test("Pairs join with an ampersand")
        func pair() {
            let query = LibraryQuery(genres: ["Horror", "Comedy"])
            #expect(query.activeFilterSummary == "Comedy & Horror")
        }

        @Test("Three or more values are all named — nothing is elided")
        func noElision() {
            let query = LibraryQuery(genres: ["Horror", "Comedy", "Drama", "Action"])
            let summary = query.activeFilterSummary
            #expect(summary == "Action, Comedy, Drama & Horror")
            // The guilty pill must be visible however the copy is punctuated
            #expect(!summary.contains("More"))
            for genre in ["Horror", "Comedy", "Drama", "Action"] {
                #expect(summary.contains(genre))
            }
        }

        @Test("Decades are named in full, without grouping separators")
        func decades() {
            let query = LibraryQuery(decades: [1990, 1980, 2020])
            #expect(query.activeFilterSummary == "1980s, 1990s & 2020s")
        }

        @Test("Every dimension reads in the header's order")
        func fullHouse() {
            let query = LibraryQuery(
                genres: ["Western"],
                decades: [1970],
                watched: .unplayed,
                favoritesOnly: true,
                officialRatings: ["R"],
            )
            #expect(
                query.activeFilterSummary
                    == "Unwatched · Favorites · Western · 1970s · Rated R",
            )
        }

        @Test("Watched reads as Watched")
        func watched() {
            #expect(LibraryQuery(watched: .played).activeFilterSummary == "Watched")
        }

        @Test("Favorites alone is a filter")
        func favoritesOnly() {
            #expect(LibraryQuery(favoritesOnly: true).activeFilterSummary == "Favorites")
        }

        @Test("Multiple ratings share one Rated prefix")
        func ratings() {
            let query = LibraryQuery(officialRatings: ["R", "PG-13", "PG"])
            #expect(query.activeFilterSummary == "Rated PG, PG-13 & R")
        }
    }
}

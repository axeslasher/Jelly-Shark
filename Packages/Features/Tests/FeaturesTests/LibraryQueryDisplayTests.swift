import Testing
import JellyfinKit
@testable import Features

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
                    == "Comedy & Horror Movies from the 1980s & 1990s"
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
                officialRatings: ["R"]
            )
            #expect(
                query.displayTitle(libraryName: "Movies")
                    == "Unwatched Favorite Western Movies rated R"
            )
        }

        @Test("Decade names never pick up grouping separators")
        func decadeFormatting() {
            let query = LibraryQuery(decades: [2020])
            #expect(query.displayTitle(libraryName: "Shows") == "Shows from the 2020s")
        }
    }
}

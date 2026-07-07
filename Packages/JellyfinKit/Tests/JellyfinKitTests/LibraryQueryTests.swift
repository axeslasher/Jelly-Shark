import Testing
import Foundation
import JellyfinAPI
@testable import JellyfinKit

@Suite("LibraryQuery")
struct LibraryQueryTests {

    @Suite("Expanded years")
    struct ExpandedYearsTests {
        @Test("Decades expand to their concrete years, sorted")
        func decadesExpand() {
            let query = LibraryQuery(decades: [2000, 1980])

            let years = query.expandedYears

            #expect(years?.count == 20)
            #expect(years?.first == 1980)
            #expect(years?.last == 2009)
            #expect(years?.contains(1985) == true)
            #expect(years?.contains(1995) == false)
        }

        @Test("No decades selected yields nil")
        func emptyDecades() {
            #expect(LibraryQuery().expandedYears == nil)
        }
    }

    @Suite("Filter options decades")
    struct FilterOptionsDecadesTests {
        @Test("Years group into deduped decades, newest first")
        func decadeGrouping() {
            let options = LibraryFilterOptions(
                genres: [],
                officialRatings: [],
                years: [1994, 1997, 2003]
            )

            #expect(options.decades == [2000, 1990])
        }

        @Test("Empty years yield no decades")
        func emptyYears() {
            #expect(LibraryFilterOptions.empty.decades.isEmpty)
        }
    }

    @Suite("SDK sort mapping")
    struct SortMappingTests {
        @Test("Each sort maps to server keys with deterministic tie-breakers")
        func sortByMapping() {
            #expect(LibrarySort.name.sdkSortBy == [.sortName])
            #expect(LibrarySort.releaseDate.sdkSortBy == [.premiereDate, .productionYear, .sortName])
            #expect(LibrarySort.dateAdded.sdkSortBy == [.dateCreated, .sortName])
            #expect(LibrarySort.communityRating.sdkSortBy == [.communityRating, .sortName])
            #expect(LibrarySort.criticRating.sdkSortBy == [.criticRating, .sortName])
        }

        @Test("Directions map to SDK sort orders")
        func sortOrderMapping() {
            #expect(LibrarySortDirection.ascending.sdkSortOrder == .ascending)
            #expect(LibrarySortDirection.descending.sdkSortOrder == .descending)
        }
    }

    @Suite("SDK filter mapping")
    struct FilterMappingTests {
        @Test("Default query produces no server filters")
        func defaultsToNil() {
            #expect(LibraryQuery().sdkFilters == nil)
        }

        @Test("Unplayed plus favorites combine")
        func unplayedAndFavorites() {
            let query = LibraryQuery(watched: .unplayed, favoritesOnly: true)
            #expect(query.sdkFilters == [.isUnplayed, .isFavorite])
        }

        @Test("Played maps alone")
        func playedOnly() {
            let query = LibraryQuery(watched: .played)
            #expect(query.sdkFilters == [.isPlayed])
        }
    }

    @Suite("MediaItemPage")
    struct MediaItemPageTests {
        private func makeItems(_ count: Int) -> [MediaItem] {
            (0..<count).map { MediaItem(id: "item-\($0)", name: "Item \($0)", type: .movie) }
        }

        @Test("First page of many has more")
        func firstPageHasMore() {
            let page = MediaItemPage(items: makeItems(100), startIndex: 0, totalRecordCount: 250)
            #expect(page.hasMore)
        }

        @Test("Last page has no more")
        func lastPageExhausted() {
            let page = MediaItemPage(items: makeItems(50), startIndex: 200, totalRecordCount: 250)
            #expect(!page.hasMore)
        }

        @Test("Unknown total assumes more while pages are non-empty")
        func unknownTotal() {
            let fullPage = MediaItemPage(items: makeItems(10), startIndex: 0, totalRecordCount: nil)
            #expect(fullPage.hasMore)

            let emptyPage = MediaItemPage(items: [], startIndex: 10, totalRecordCount: nil)
            #expect(!emptyPage.hasMore)
        }
    }

    @Suite("Query state")
    struct QueryStateTests {
        @Test("Default query is not filtering")
        func defaultNotFiltering() {
            #expect(!LibraryQuery().isFiltering)
        }

        @Test("Sort changes alone are not filtering")
        func sortIsNotAFilter() {
            let query = LibraryQuery(sort: .communityRating, direction: .descending)
            #expect(!query.isFiltering)
        }

        @Test("Any filter marks the query as filtering")
        func filtersAreFiltering() {
            #expect(LibraryQuery(genres: ["Horror"]).isFiltering)
            #expect(LibraryQuery(decades: [1990]).isFiltering)
            #expect(LibraryQuery(watched: .unplayed).isFiltering)
            #expect(LibraryQuery(favoritesOnly: true).isFiltering)
            #expect(LibraryQuery(officialRatings: ["R"]).isFiltering)
        }

        @Test("Clearing filters preserves sort")
        func clearPreservesSort() {
            let query = LibraryQuery(
                sort: .criticRating,
                direction: .descending,
                genres: ["Action"],
                favoritesOnly: true
            )

            let cleared = query.withFiltersCleared

            #expect(!cleared.isFiltering)
            #expect(cleared.sort == .criticRating)
            #expect(cleared.direction == .descending)
        }
    }
}

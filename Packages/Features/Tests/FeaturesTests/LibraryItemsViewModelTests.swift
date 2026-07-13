@testable import Features
import Foundation
import JellyfinKit
import Testing

@MainActor
@Suite("LibraryItemsViewModel")
struct LibraryItemsViewModelTests {
    private static let library = Library(id: "lib-1", name: "Movies", collectionType: .movies)

    private func makeItems(_ range: Range<Int>) -> [MediaItem] {
        range.map { MediaItem(id: "item-\($0)", name: "Item \($0)", type: .movie) }
    }

    private func makeViewModel(
        client: MockJellyfinClient,
        pageSize: Int = 3,
    ) -> LibraryItemsViewModel {
        let viewModel = LibraryItemsViewModel(pageSize: pageSize, prefetchDistance: 2)
        viewModel.attach(client: client, library: Self.library)
        return viewModel
    }

    // MARK: - Initial load

    @Test("Initial load requests the first page and lands in loaded")
    func initialLoad() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 8)),
        ]
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.items.count == 3)
        #expect(viewModel.totalCount == 8)
        #expect(viewModel.countLabel == "8 items")
        #expect(client.libraryItemsRequests.count == 1)
        #expect(client.libraryItemsRequests[0].libraryId == "lib-1")
        #expect(client.libraryItemsRequests[0].startIndex == 0)
        #expect(client.libraryItemsRequests[0].limit == 3)
    }

    @Test("An initial query seeds the grid's genre filter, title, and request")
    func initialQuerySeeds() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = LibraryItemsViewModel(pageSize: 3, prefetchDistance: 2)
        viewModel.attach(client: client, library: Self.library, initialQuery: LibraryQuery(genres: ["Horror"]))

        await viewModel.loadInitial()

        #expect(viewModel.query.genres == ["Horror"])
        #expect(viewModel.query.isFiltering)
        #expect(viewModel.displayTitle == "Horror Movies")
        #expect(client.libraryItemsRequests.count == 1)
        #expect(client.libraryItemsRequests[0].query.genres == ["Horror"])
    }

    @Test("No initial query leaves the grid unfiltered")
    func noInitialQueryUnfiltered() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        #expect(viewModel.query.genres.isEmpty)
        #expect(!viewModel.query.isFiltering)
        #expect(client.libraryItemsRequests[0].query.genres.isEmpty)
    }

    @Test("Empty first page lands in empty")
    func emptyLibrary() async {
        let client = MockJellyfinClient()
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        #expect(viewModel.state == .empty)
        #expect(viewModel.items.isEmpty)
    }

    @Test("Failed first page lands in failed")
    func failedFirstPage() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.failure(APIError.serverError(statusCode: 500))]
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }
    }

    @Test("Missing client fails without a request")
    func missingClient() async {
        let viewModel = LibraryItemsViewModel(pageSize: 3)
        viewModel.attach(client: nil, library: Self.library)

        await viewModel.loadInitial()

        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }
    }

    @Test("Reappearance does not reload an already-loaded grid")
    func reappearanceIsNoOp() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        // The view's .task re-fires attach + loadInitial on every appearance
        viewModel.attach(client: client, library: Self.library)
        await viewModel.loadInitial()

        #expect(client.libraryItemsRequests.count == 1)
        #expect(viewModel.state == .loaded)
        #expect(viewModel.items.count == 3)
    }

    @Test("A new client triggers a fresh load")
    func newClientReloads() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        let reconnectedClient = MockJellyfinClient()
        reconnectedClient.libraryItemsPages = client.libraryItemsPages
        viewModel.attach(client: reconnectedClient, library: Self.library)
        await viewModel.loadInitial()

        #expect(client.libraryItemsRequests.count == 1)
        #expect(reconnectedClient.libraryItemsRequests.count == 1)
    }

    @Test("A failed initial load retries on the next appearance")
    func failedInitialLoadRetries() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .failure(APIError.serverError(statusCode: 500)),
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()
        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }

        viewModel.attach(client: client, library: Self.library)
        await viewModel.loadInitial()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.items.count == 3)
    }

    // MARK: - Pagination

    @Test("Reaching the end of the grid fetches the next page")
    func paginationAppends() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 5)),
            .success(MediaItemPage(items: makeItems(3 ..< 5), startIndex: 3, totalRecordCount: 5)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await viewModel.awaitPendingLoad()

        #expect(viewModel.items.count == 5)
        #expect(Set(viewModel.items.map(\.id)).count == 5)
        #expect(client.libraryItemsRequests.count == 2)
        #expect(client.libraryItemsRequests[1].startIndex == 3)
    }

    @Test("Items far from the end do not trigger a fetch")
    func farFromEndNoFetch() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 5), startIndex: 0, totalRecordCount: 10)),
        ]
        let viewModel = makeViewModel(client: client, pageSize: 5)
        await viewModel.loadInitial()

        viewModel.loadMoreIfNeeded(currentItem: viewModel.items[0])

        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("No fetch once everything is loaded")
    func exhaustedNoFetch() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await viewModel.awaitPendingLoad()

        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("Rapid prefetch triggers issue a single request")
    func noDoubleFire() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 9)),
            .success(MediaItemPage(items: makeItems(3 ..< 6), startIndex: 3, totalRecordCount: 9)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await viewModel.awaitPendingLoad()

        #expect(client.libraryItemsRequests.count == 2)
    }

    @Test("A failed follow-up page keeps the grid and allows retry")
    func failedPageKeepsGrid() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 6)),
            .failure(APIError.serverError(statusCode: 500)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await viewModel.awaitPendingLoad()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.items.count == 3)
        #expect(!viewModel.isLoadingMore)

        // Scrolling near the end again retries
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await viewModel.awaitPendingLoad()
        #expect(client.libraryItemsRequests.count == 3)
    }

    // MARK: - Query changes

    @Test("A query change resets the grid and carries the new selections")
    func queryChangeResets() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 8)),
            .success(MediaItemPage(items: makeItems(10 ..< 12), startIndex: 0, totalRecordCount: 2)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.genres = ["Horror"]
        query.sort = .communityRating
        query.direction = .descending
        viewModel.update(query: query)

        // The previous grid stays up (dimmed) while the new query loads, so
        // menu dismissal has a stable hierarchy to restore focus through
        #expect(viewModel.state == .loaded)
        #expect(viewModel.isReloading)
        #expect(viewModel.items.count == 3)
        // ...but the stale grid must not prefetch pages of the new query
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)

        await viewModel.awaitPendingLoad()

        // Exactly two requests: initial load and the new query's first page —
        // no prefetch snuck in off the stale grid
        #expect(client.libraryItemsRequests.count == 2)
        #expect(viewModel.state == .loaded)
        #expect(!viewModel.isReloading)
        #expect(viewModel.items.map(\.id) == ["item-10", "item-11"])
        #expect(viewModel.totalCount == 2)
        let request = client.libraryItemsRequests[1]
        #expect(request.startIndex == 0)
        #expect(request.query.genres == ["Horror"])
        #expect(request.query.sort == .communityRating)
    }

    @Test("Setting the same query is a no-op")
    func sameQueryNoOp() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        viewModel.update(query: viewModel.query)

        #expect(viewModel.state == .loaded)
        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("A stale in-flight page is discarded after a query change")
    func staleResponseDiscarded() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 9)),
            .success(MediaItemPage(items: makeItems(3 ..< 6), startIndex: 3, totalRecordCount: 9)),
            .success(MediaItemPage(items: makeItems(20 ..< 22), startIndex: 0, totalRecordCount: 2)),
        ]
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        // Gate page 2 so the query change lands while it is in flight
        let gate = AsyncGate()
        client.libraryItemsDelay = { await gate.wait() }
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)

        client.libraryItemsDelay = nil
        var query = viewModel.query
        query.favoritesOnly = true
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()

        await gate.open()

        // The stale page-2 items (3..<6) must never appear
        #expect(viewModel.items.map(\.id) == ["item-20", "item-21"])
        #expect(viewModel.totalCount == 2)
    }

    // MARK: - Filter options

    @Test("Filter options load alongside the first page")
    func filterOptionsLoad() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Horror"], officialRatings: ["R"], years: [1985]),
        )
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        #expect(viewModel.filterOptions.genres == ["Horror"])
        #expect(viewModel.filterOptions.decades == [1980])
    }

    @Test("A genre pick narrows decades and ratings, never other genres")
    func narrowingApplies() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .success(
            LibraryFilterOptions(
                genres: ["Comedy", "Horror", "Western"],
                officialRatings: ["PG", "R"],
                years: [1969, 1985, 2021],
            ),
        )
        client.narrowedOptionsResult = .success(
            LibraryFilterOptions(genres: ["Western"], officialRatings: ["R"], years: [1969]),
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.genres = ["Western"]
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()

        // One scan: decades and ratings share the same "everything but my
        // own selection" query, and the genre menu (whose remaining filters
        // are empty) needs none
        #expect(client.narrowedOptionsRequests.count == 1)
        #expect(client.narrowedOptionsRequests[0].genres == ["Western"])
        // 2020s vanish from the menus: no westerns there
        #expect(viewModel.visibleFilterOptions.decades == [1960])
        #expect(viewModel.visibleFilterOptions.officialRatings == ["R"])
        // The genre menu keeps the full list — its own picks don't narrow it
        #expect(viewModel.visibleFilterOptions.genres == ["Comedy", "Horror", "Western"])
    }

    @Test("A decade pick leaves the other decades available")
    func decadesDoNotNarrowThemselves() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .success(
            LibraryFilterOptions(
                genres: ["Comedy", "Western"],
                officialRatings: ["PG", "R"],
                years: [1969, 1985, 2021],
            ),
        )
        client.narrowedOptionsResult = .success(
            LibraryFilterOptions(genres: ["Western"], officialRatings: ["R"], years: [1969]),
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.decades = [1960]
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()

        // Genres and ratings narrow to the 1960s scan; every decade stays
        #expect(viewModel.visibleFilterOptions.decades == [2020, 1980, 1960])
        #expect(viewModel.visibleFilterOptions.genres == ["Western"])
        #expect(viewModel.visibleFilterOptions.officialRatings == ["R"])
    }

    @Test("Cross-narrowing: each menu scans without its own selection")
    func crossNarrowing() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .success(
            LibraryFilterOptions(
                genres: ["Comedy", "Horror", "Western"],
                officialRatings: ["PG", "R"],
                years: [1969, 1985, 2021],
            ),
        )
        client.narrowedOptionsHandler = { scanQuery in
            if scanQuery.genres.isEmpty {
                // Scan for the genre menu: 1960s only
                return .success(
                    LibraryFilterOptions(genres: ["Comedy", "Western"], officialRatings: ["PG"], years: [1969]),
                )
            }
            // Scan for the decades/ratings menus: Western only
            return .success(
                LibraryFilterOptions(genres: ["Western"], officialRatings: ["R"], years: [1969, 1985]),
            )
        }
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.genres = ["Western"]
        query.decades = [1960]
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()

        // Three dimensions, but decades and ratings share no query with
        // genres: genres scanned decades-only, decades scanned genres-only,
        // ratings scanned genres+decades
        #expect(client.narrowedOptionsRequests.count == 3)
        #expect(viewModel.visibleFilterOptions.genres == ["Comedy", "Western"])
        #expect(viewModel.visibleFilterOptions.decades == [1980, 1960])
    }

    @Test("Selected values stay in the menus even when narrowed out")
    func selectionsSurviveNarrowing() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: [], startIndex: 0, totalRecordCount: 0)),
        ]
        client.narrowedOptionsResult = .success(
            LibraryFilterOptions(genres: [], officialRatings: [], years: []),
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.genres = ["Western"]
        query.decades = [2020]
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()

        #expect(viewModel.visibleFilterOptions.genres == ["Western"])
        #expect(viewModel.visibleFilterOptions.decades == [2020])
    }

    @Test("A bailed-out narrowing scan falls back to the full options")
    func narrowingBailoutFallsBack() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Comedy", "Horror"], officialRatings: [], years: []),
        )
        client.narrowedOptionsResult = .success(nil)
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.favoritesOnly = true
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()

        #expect(viewModel.visibleFilterOptions.genres == ["Comedy", "Horror"])
    }

    @Test("Clearing filters restores the full options without a scan")
    func clearRestoresFullOptions() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Comedy", "Horror"], officialRatings: ["PG", "R"], years: []),
        )
        client.narrowedOptionsResult = .success(
            LibraryFilterOptions(genres: ["Horror"], officialRatings: ["R"], years: []),
        )
        let viewModel = makeViewModel(client: client)
        await viewModel.loadInitial()

        var query = viewModel.query
        query.genres = ["Horror"]
        viewModel.update(query: query)
        await viewModel.awaitPendingLoad()
        #expect(viewModel.visibleFilterOptions.officialRatings == ["R"])

        viewModel.update(query: viewModel.query.withFiltersCleared)
        await viewModel.awaitPendingLoad()

        #expect(viewModel.visibleFilterOptions.officialRatings == ["PG", "R"])
        // No filters → no narrowing scan for the cleared query
        #expect(client.narrowedOptionsRequests.count == 1)
    }

    @Test("The unfiltered grid gets no narrowing scan")
    func noScanWhenUnfiltered() async {
        let client = MockJellyfinClient()
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        #expect(client.narrowedOptionsRequests.isEmpty)
    }

    @Test("A filter-options failure does not fail the grid")
    func filterOptionsFailureIsNonFatal() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: makeItems(0 ..< 3), startIndex: 0, totalRecordCount: 3)),
        ]
        client.filterOptionsResult = .failure(APIError.serverError(statusCode: 500))
        let viewModel = makeViewModel(client: client)

        await viewModel.loadInitial()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.filterOptions == .empty)
    }
}

/// A reusable async gate: `wait()` suspends until `open()` is called.
/// Target-visible: HomeViewModelTests gates in-flight loads with it too.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

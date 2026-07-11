import Foundation
import JellyfinKit
import Observation

/// View model backing a library's item grid.
///
/// Owns the paginated query → items pipeline: infinite scroll, filter/sort
/// changes that reset the grid, and the library's filter menu options.
@Observable
@MainActor
public final class LibraryItemsViewModel {
    /// The lifecycle of the current query's results.
    public enum State: Equatable {
        /// The first page of the current query is in flight; grid empty.
        case loading
        /// Items are on screen (more pages may still stream in).
        case loaded
        /// The current query returned nothing.
        case empty
        /// The first page failed; carries a user-facing message.
        case failed(String)
    }

    // MARK: - State

    /// All items loaded so far for the current query.
    public private(set) var items: [MediaItem] = []

    /// The current query lifecycle state.
    public private(set) var state: State = .loading

    /// Total item count for the current query, once the first page lands.
    public private(set) var totalCount: Int?

    /// True while a follow-up page is in flight.
    public private(set) var isLoadingMore = false

    /// True while a query change's first page is in flight. The previous
    /// grid stays on screen (slightly dimmed) until the new results land —
    /// tearing it down mid-menu-dismissal stalls the tvOS focus engine's
    /// return to the control bar.
    public private(set) var isReloading = false

    /// Filter values present in this library, for the control bar menus.
    public private(set) var filterOptions: LibraryFilterOptions = .empty

    /// Narrowed option lists per menu, each computed with that menu's own
    /// selection excluded — a decade pick must not hide other decades, only
    /// the *other* filters narrow a menu. Nil means no narrowing applies
    /// (that menu's remaining filters are empty, or the scan bailed out).
    private var narrowedGenres: [String]?
    private var narrowedYears: [Int]?
    private var narrowedRatings: [String]?

    /// The active sort and filter selections.
    public private(set) var query = LibraryQuery()

    // MARK: - Configuration

    private let pageSize: Int

    /// Distance from the end of the grid (in items) that triggers a prefetch;
    /// roughly two rows ahead of the focus.
    private let prefetchDistance: Int

    private var client: (any JellyfinClientProtocol)?
    private var library: Library?

    /// Whether loadInitial() should actually load. The view's `.task` re-runs
    /// on every appearance — including returning from a fullscreen tvOS menu —
    /// and reloading then would tear down the grid right as the focus engine
    /// tries to restore focus to the control bar.
    private var needsInitialLoad = true

    /// The in-flight page task, retained so it can be cancelled.
    private var loadTask: Task<Void, Never>?

    /// Bumped whenever the query changes so stale responses are discarded.
    private var loadGeneration = 0

    public init(pageSize: Int = 100, prefetchDistance: Int = 18) {
        self.pageSize = pageSize
        self.prefetchDistance = prefetchDistance
    }

    // MARK: - Derived

    public var hasMore: Bool {
        guard let totalCount else { return false }
        return items.count < totalCount
    }

    /// A "1,234 items" subtitle, nil until the first page lands.
    public var countLabel: String? {
        guard let totalCount else { return nil }
        return totalCount == 1 ? "1 item" : "\(totalCount.formatted()) items"
    }

    /// The headline for the grid: "All Movies" or a description of the
    /// active filters ("Horror Movies from the 1980s").
    public var displayTitle: String? {
        guard let library else { return nil }
        return query.displayTitle(libraryName: library.name)
    }

    /// The options the control bar should offer: each menu narrowed to
    /// values that still yield results under the *other* filters, always
    /// including current selections so anything applied can be unapplied.
    public var visibleFilterOptions: LibraryFilterOptions {
        LibraryFilterOptions(
            genres: merged(narrowedGenres, base: filterOptions.genres, selected: query.genres),
            officialRatings: merged(
                narrowedRatings, base: filterOptions.officialRatings, selected: query.officialRatings,
            ),
            // A selected decade's start year stands in for the whole decade
            years: merged(narrowedYears, base: filterOptions.years, selected: query.decades),
        )
    }

    private func merged<Value: Hashable & Comparable>(
        _ narrowed: [Value]?,
        base: [Value],
        selected: Set<Value>,
    ) -> [Value] {
        guard let narrowed else { return base }
        return Set(narrowed).union(selected).sorted()
    }

    // MARK: - Actions

    /// Attach the authenticated client and library (called by the view on
    /// every appearance). Only an actual change — a new session's client or
    /// a different library — schedules a fresh initial load.
    ///
    /// `initialQuery` seeds the sort/filter selection for that fresh load (e.g.
    /// a genre card pushes a genre-filtered grid); it's applied only when a
    /// reload is scheduled, so returning to the view preserves any filters the
    /// user has since changed. Omit it for the default unfiltered grid.
    public func attach(
        client: (any JellyfinClientProtocol)?,
        library: Library,
        initialQuery: LibraryQuery? = nil,
    ) {
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let libraryChanged = library.id != self.library?.id
        self.client = client
        self.library = library
        if clientChanged || libraryChanged {
            needsInitialLoad = true
            query = initialQuery ?? LibraryQuery()
        }
    }

    /// Load the first page and the library's filter options together.
    /// No-op when the attached client and library have already loaded, so
    /// view reappearances (returning from a menu or a pushed detail screen)
    /// don't reload the grid.
    public func loadInitial() async {
        guard needsInitialLoad else { return }
        needsInitialLoad = false

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        items = []
        totalCount = nil
        isReloading = false
        state = .loading

        guard let client, let library else {
            state = .failed(APIError.notAuthenticated.localizedDescription)
            return
        }

        // Menu options load alongside the first page; their failure is
        // non-fatal — the bar just offers fewer menus.
        async let optionsFetch = try? client.getLibraryFilterOptions(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes,
        )

        await loadFirstPage(client: client, library: library, generation: generation)

        // A failed first load retries on the next appearance
        if generation == loadGeneration, case .failed = state {
            needsInitialLoad = true
        }

        if let options = await optionsFetch, generation == loadGeneration {
            filterOptions = options
        }

        await refreshNarrowedOptions(client: client, library: library, generation: generation)
    }

    /// Apply a new sort/filter selection: reset the grid and refetch.
    public func update(query newQuery: LibraryQuery) {
        guard newQuery != query else { return }
        query = newQuery

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        isLoadingMore = false
        isReloading = true
        // Keep the current items visible while the new query loads; only an
        // already-empty grid shows the spinner
        if items.isEmpty {
            state = .loading
        }
        if !newQuery.isFiltering {
            narrowedGenres = nil
            narrowedYears = nil
            narrowedRatings = nil
        }

        guard let client, let library else {
            isReloading = false
            state = .failed(APIError.notAuthenticated.localizedDescription)
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            async let firstPage: Void = self.loadFirstPage(
                client: client, library: library, generation: generation,
            )
            async let narrowing: Void = self.refreshNarrowedOptions(
                client: client, library: library, generation: generation,
            )
            _ = await (firstPage, narrowing)
        }
    }

    /// Prefetch the next page when the given item is near the end of the grid.
    public func loadMoreIfNeeded(currentItem: MediaItem) {
        // No prefetch off the stale grid during a reload: its item count
        // would page the *new* query from the wrong offset
        guard !isLoadingMore, !isReloading, hasMore, state == .loaded else { return }
        guard let client, let library else { return }
        guard let index = items.firstIndex(of: currentItem),
              index >= items.count - prefetchDistance else { return }

        isLoadingMore = true
        let generation = loadGeneration
        let startIndex = items.count

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await client.getLibraryItems(
                    libraryId: library.id,
                    itemTypes: library.collectionType?.gridItemTypes,
                    query: self.query,
                    limit: self.pageSize,
                    startIndex: startIndex,
                )
                guard generation == self.loadGeneration else { return }
                self.items.append(contentsOf: page.items)
                self.totalCount = page.totalRecordCount ?? self.totalCount
                self.isLoadingMore = false
            } catch {
                // A failed follow-up page keeps the grid; scrolling near the
                // end again retries.
                guard generation == self.loadGeneration else { return }
                self.isLoadingMore = false
            }
        }
    }

    /// Awaits completion of the in-flight page load, if any.
    ///
    /// Intended for tests to observe results deterministically without sleeping.
    func awaitPendingLoad() async {
        await loadTask?.value
    }

    // MARK: - Loading

    /// Recompute which filter values still yield results for each menu,
    /// scanning with that menu's own selection excluded (so a decade pick
    /// narrows genres and ratings, never other decades). Scans sharing the
    /// same effective query are deduplicated. Failure or bail-out (result
    /// set too large) is non-fatal — that menu falls back to full options.
    private func refreshNarrowedOptions(
        client: any JellyfinClientProtocol,
        library: Library,
        generation: Int,
    ) async {
        var minusGenres = query
        minusGenres.genres = []
        var minusDecades = query
        minusDecades.decades = []
        var minusRatings = query
        minusRatings.officialRatings = []

        // A menu whose remaining filters are empty needs no scan: the full
        // library options apply
        let scanQueries = Set([minusGenres, minusDecades, minusRatings].filter(\.isFiltering))
        let itemTypes = library.collectionType?.gridItemTypes
        let libraryId = library.id

        var results: [LibraryQuery: LibraryFilterOptions] = [:]
        await withTaskGroup(of: (LibraryQuery, LibraryFilterOptions?).self) { group in
            for scanQuery in scanQueries {
                group.addTask {
                    let options = await (try? client.getLibraryFilterOptions(
                        libraryId: libraryId,
                        itemTypes: itemTypes,
                        matching: scanQuery,
                    )) ?? nil
                    return (scanQuery, options)
                }
            }
            for await (scanQuery, options) in group {
                results[scanQuery] = options
            }
        }

        guard generation == loadGeneration else { return }
        // Assign only on change: these land right in the menu-dismissal
        // window, and a spurious write rebuilds the control bar while the
        // focus engine is trying to settle back onto it
        let genres = results[minusGenres]?.genres
        let years = results[minusDecades]?.years
        let ratings = results[minusRatings]?.officialRatings
        if narrowedGenres != genres {
            narrowedGenres = genres
        }
        if narrowedYears != years {
            narrowedYears = years
        }
        if narrowedRatings != ratings {
            narrowedRatings = ratings
        }
    }

    private func loadFirstPage(
        client: any JellyfinClientProtocol,
        library: Library,
        generation: Int,
    ) async {
        do {
            let page = try await client.getLibraryItems(
                libraryId: library.id,
                itemTypes: library.collectionType?.gridItemTypes,
                query: query,
                limit: pageSize,
                startIndex: 0,
            )
            guard generation == loadGeneration else { return }
            items = page.items
            totalCount = page.totalRecordCount ?? page.items.count
            isReloading = false
            state = items.isEmpty ? .empty : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            items = []
            totalCount = nil
            isReloading = false
            state = .failed(error.localizedDescription)
        }
    }
}

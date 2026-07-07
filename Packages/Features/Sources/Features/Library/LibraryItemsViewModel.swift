import Foundation
import Observation
import JellyfinKit

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

    /// Filter values present in this library, for the control bar menus.
    public private(set) var filterOptions: LibraryFilterOptions = .empty

    /// The active sort and filter selections.
    public private(set) var query = LibraryQuery()

    // MARK: - Configuration

    private let pageSize: Int

    /// Distance from the end of the grid (in items) that triggers a prefetch;
    /// roughly two rows ahead of the focus.
    private let prefetchDistance: Int

    private var client: (any JellyfinClientProtocol)?
    private var library: Library?

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

    // MARK: - Actions

    /// Attach the authenticated client and library (called by the view once
    /// the session connects).
    public func attach(client: (any JellyfinClientProtocol)?, library: Library) {
        self.client = client
        self.library = library
    }

    /// Load the first page and the library's filter options together.
    public func loadInitial() async {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        items = []
        totalCount = nil
        state = .loading

        guard let client, let library else {
            state = .failed(APIError.notAuthenticated.localizedDescription)
            return
        }

        // Menu options load alongside the first page; their failure is
        // non-fatal — the bar just offers fewer menus.
        async let optionsFetch = try? client.getLibraryFilterOptions(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes
        )

        await loadFirstPage(client: client, library: library, generation: generation)

        if let options = await optionsFetch, generation == loadGeneration {
            filterOptions = options
        }
    }

    /// Apply a new sort/filter selection: reset the grid and refetch.
    public func update(query newQuery: LibraryQuery) {
        guard newQuery != query else { return }
        query = newQuery

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        items = []
        totalCount = nil
        isLoadingMore = false
        state = .loading

        guard let client, let library else {
            state = .failed(APIError.notAuthenticated.localizedDescription)
            return
        }

        loadTask = Task { [weak self] in
            await self?.loadFirstPage(client: client, library: library, generation: generation)
        }
    }

    /// Prefetch the next page when the given item is near the end of the grid.
    public func loadMoreIfNeeded(currentItem: MediaItem) {
        guard !isLoadingMore, hasMore, state == .loaded else { return }
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
                    startIndex: startIndex
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

    private func loadFirstPage(
        client: any JellyfinClientProtocol,
        library: Library,
        generation: Int
    ) async {
        do {
            let page = try await client.getLibraryItems(
                libraryId: library.id,
                itemTypes: library.collectionType?.gridItemTypes,
                query: query,
                limit: pageSize,
                startIndex: 0
            )
            guard generation == loadGeneration else { return }
            items = page.items
            totalCount = page.totalRecordCount ?? page.items.count
            state = items.isEmpty ? .empty : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

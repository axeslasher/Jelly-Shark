import Foundation
import JellyfinKit
import Observation

/// Builds the Home "Browse by genre" shelves: one per genre-capable library
/// (movies and TV), each listing the library's genres alphabetically.
///
/// Only the genre lists are built here (one cheap filter-options call per
/// library); each card fetches its own representative backdrop lazily as it
/// scrolls into view (see `GenreCardView`), so coverage never depends on a
/// single sampled page.
@Observable
@MainActor
public final class GenreShelvesViewModel {
    /// Lifecycle of the genre section (same shape as
    /// `HomeViewModel.SectionStatus`).
    public enum Status: Equatable {
        case loading
        case loaded
        /// Built successfully but there is nothing to show — no genre-capable
        /// libraries, or none reported genres (not an error).
        case empty
        case failed(String)

        var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    /// A genre row for one library.
    public struct Shelf: Identifiable, Sendable {
        public let library: Library
        public let genres: [String]
        public var id: String {
            library.id
        }
    }

    /// Library kinds whose items are meaningfully organized by genre.
    private static let genreCapable: Set<CollectionType> = [.movies, .tvshows]

    public private(set) var shelves: [Shelf] = []
    public private(set) var status: Status = .loading

    private let genreLimit: Int

    private var client: (any JellyfinClientProtocol)?
    private var libraries: [Library] = []

    /// Genres are stable, so we build the shelves once per connection rather than
    /// on every return to Home (mirrors `LibraryItemsViewModel.needsInitialLoad`);
    /// a failed build re-arms this so the next appearance retries.
    private var needsLoad = true
    private var loadGeneration = 0

    public init(genreLimit: Int = 50) {
        self.genreLimit = genreLimit
    }

    /// Attach the client and library list (called by the view on appearance).
    /// Only an actual change schedules a rebuild.
    public func attach(client: (any JellyfinClientProtocol)?, libraries: [Library]) {
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let librariesChanged = libraries.map(\.id) != self.libraries.map(\.id)
        self.client = client
        self.libraries = libraries
        if clientChanged || librariesChanged {
            needsLoad = true
        }
    }

    /// Build the shelves. No-op once built for the current client + libraries.
    public func load() async {
        guard needsLoad else { return }
        needsLoad = false
        loadGeneration += 1
        let generation = loadGeneration

        guard let client else {
            // Session still settling (or torn down) — park at `.loading`, not
            // `.empty` or `.failed` (mirrors `HomeViewModel.load`).
            shelves = []
            status = .loading
            return
        }
        let genreLibraries = libraries.filter { library in
            library.collectionType.map(Self.genreCapable.contains) ?? false
        }
        guard !genreLibraries.isEmpty else {
            shelves = []
            status = .empty
            return
        }

        let (built, firstError) = await Self.buildShelves(
            client: client,
            libraries: genreLibraries,
            genreLimit: genreLimit,
        )
        guard generation == loadGeneration else { return }
        shelves = built
        if let firstError {
            // Show what survived, but re-arm so the next appearance (or the
            // notice's Retry) refetches; report failure only when nothing did.
            needsLoad = true
            status = built.isEmpty ? .failed(firstError) : .loaded
        } else {
            status = built.isEmpty ? .empty : .loaded
        }
    }

    /// Re-run the build now — the failed notice's Retry button.
    public func retry() async {
        needsLoad = true
        await load()
    }

    // MARK: - Building

    /// One filter-options fetch per library, concurrently, in library order.
    /// Genre-less libraries simply contribute no shelf; failed ones also
    /// report back (as the first failure's description, in library order) so
    /// `load()` can surface the error instead of silently blanking the section.
    private nonisolated static func buildShelves(
        client: any JellyfinClientProtocol,
        libraries: [Library],
        genreLimit: Int,
    ) async -> (shelves: [Shelf], firstError: String?) {
        let byIndex = await withTaskGroup(of: (Int, Result<Shelf?, Error>).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    do {
                        return try await (index, .success(buildShelf(client: client, library: library, genreLimit: genreLimit)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results: [Int: Result<Shelf?, Error>] = [:]
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }

        var shelves: [Shelf] = []
        var firstError: String?
        for index in libraries.indices {
            switch byIndex[index] {
            case let .success(shelf?):
                shelves.append(shelf)
            case let .failure(error):
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            case .success(nil), .none:
                break
            }
        }
        return (shelves, firstError)
    }

    private nonisolated static func buildShelf(
        client: any JellyfinClientProtocol,
        library: Library,
        genreLimit: Int,
    ) async throws -> Shelf? {
        let options = try await client.getLibraryFilterOptions(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes,
        )
        guard !options.genres.isEmpty else { return nil }

        // Legacy filter options come back in server order — sort alphabetically.
        // (Ordering by genre item-count is a plausible future user setting, but
        // these options carry no counts.)
        let genres = Array(options.genres.sorted().prefix(genreLimit))
        return Shelf(library: library, genres: genres)
    }
}

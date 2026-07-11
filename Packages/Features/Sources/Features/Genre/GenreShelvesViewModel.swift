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

    private let genreLimit: Int

    private var client: (any JellyfinClientProtocol)?
    private var libraries: [Library] = []

    /// Genres are stable, so we build the shelves once per connection rather than
    /// on every return to Home (mirrors `LibraryItemsViewModel.needsInitialLoad`).
    private var needsLoad = true

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

        guard let client else {
            shelves = []
            return
        }
        let genreLibraries = libraries.filter { library in
            library.collectionType.map(Self.genreCapable.contains) ?? false
        }
        guard !genreLibraries.isEmpty else {
            shelves = []
            return
        }

        shelves = await Self.buildShelves(client: client, libraries: genreLibraries, genreLimit: genreLimit)
    }

    // MARK: - Building

    private nonisolated static func buildShelves(
        client: any JellyfinClientProtocol,
        libraries: [Library],
        genreLimit: Int,
    ) async -> [Shelf] {
        let byIndex = await withTaskGroup(of: (Int, Shelf?).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    await (index, buildShelf(client: client, library: library, genreLimit: genreLimit))
                }
            }
            var results: [Int: Shelf] = [:]
            for await (index, shelf) in group {
                results[index] = shelf
            }
            return results
        }
        // Preserve library order; drop libraries that produced no genres.
        return libraries.indices.compactMap { byIndex[$0] }
    }

    private nonisolated static func buildShelf(
        client: any JellyfinClientProtocol,
        library: Library,
        genreLimit: Int,
    ) async -> Shelf? {
        guard let options = try? await client.getLibraryFilterOptions(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes,
        ), !options.genres.isEmpty else { return nil }

        // Legacy filter options come back in server order — sort alphabetically.
        // (Ordering by genre item-count is a plausible future user setting, but
        // these options carry no counts.)
        let genres = Array(options.genres.sorted().prefix(genreLimit))
        return Shelf(library: library, genres: genres)
    }
}

@testable import Features
import Foundation
import JellyfinKit
import Testing

@MainActor
@Suite("GenreShelvesViewModel")
struct GenreShelvesViewModelTests {
    private static let movies = Library(id: "movies", name: "Films", collectionType: .movies)
    private static let shows = Library(id: "shows", name: "Series", collectionType: .tvshows)
    private static let music = Library(id: "music", name: "Music", collectionType: .music)

    // MARK: - Shelves per library

    @Test("One shelf per genre-capable library, in library order; others skipped")
    func shelfPerGenreLibrary() async {
        let client = MockJellyfinClient()
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Horror"], officialRatings: [], years: []),
        )

        let viewModel = GenreShelvesViewModel()
        viewModel.attach(client: client, libraries: [Self.music, Self.movies, Self.shows])
        await viewModel.load()

        // Music is not genre-capable; movies + shows are, in their library order.
        #expect(viewModel.shelves.map(\.library.id) == ["movies", "shows"])
    }

    @Test("No genre-capable libraries yields no shelves")
    func noGenreLibraries() async {
        let client = MockJellyfinClient()
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Horror"], officialRatings: [], years: []),
        )
        let viewModel = GenreShelvesViewModel()
        viewModel.attach(client: client, libraries: [Self.music])
        await viewModel.load()

        #expect(viewModel.shelves.isEmpty)
    }

    @Test("A library with no genres produces no shelf")
    func noGenresNoShelf() async {
        let client = MockJellyfinClient()
        client.filterOptionsResult = .success(.empty)
        let viewModel = GenreShelvesViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        #expect(viewModel.shelves.isEmpty)
    }

    @Test("A nil client yields no shelves")
    func nilClient() async {
        let viewModel = GenreShelvesViewModel()
        viewModel.attach(client: nil, libraries: [Self.movies])
        await viewModel.load()

        #expect(viewModel.shelves.isEmpty)
    }

    // MARK: - Genre ordering & cap

    @Test("Genres are alphabetized")
    func alphaOrder() async throws {
        let client = MockJellyfinClient()
        client.filterOptionsResult = .success(
            // Deliberately unsorted to prove client-side alpha ordering.
            LibraryFilterOptions(genres: ["Horror", "Action", "Comedy"], officialRatings: [], years: []),
        )

        let viewModel = GenreShelvesViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        let shelf = try #require(viewModel.shelves.first)
        #expect(shelf.genres == ["Action", "Comedy", "Horror"])
    }

    @Test("Genres are capped, keeping the alphabetically-first N")
    func genreCap() async throws {
        let client = MockJellyfinClient()
        let manyGenres = (0 ..< 60).map { String(format: "G%02d", $0) }.shuffled()
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: manyGenres, officialRatings: [], years: []),
        )

        let viewModel = GenreShelvesViewModel(genreLimit: 50)
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        let shelf = try #require(viewModel.shelves.first)
        #expect(shelf.genres.count == 50)
        #expect(shelf.genres == (0 ..< 50).map { String(format: "G%02d", $0) })
    }

    // MARK: - Load-once

    @Test("Rebuilds once per connection; a reappearance is a no-op")
    func loadOncePerConnection() async {
        let client = MockJellyfinClient()
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Horror"], officialRatings: [], years: []),
        )

        let viewModel = GenreShelvesViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        #expect(viewModel.shelves.first?.genres == ["Horror"])

        // A reappearance re-fires attach + load; the genres must not rebuild even
        // though the client would now report something different.
        client.filterOptionsResult = .success(
            LibraryFilterOptions(genres: ["Comedy", "Drama"], officialRatings: [], years: []),
        )
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        #expect(viewModel.shelves.first?.genres == ["Horror"])
    }
}

@testable import Features
import Foundation
import JellyfinKit
import Testing

/// Declared outside the suite: a type nested in a `@MainActor` suite inherits
/// that isolation, and this one is constructed inside a stub closure the client
/// calls off the main actor.
private struct SampleFailure: Error {}

@Suite("LibraryCardViewModel")
@MainActor
struct LibraryCardViewModelTests {
    private static let movies = Library(id: "movies", name: "Films", collectionType: .movies)

    /// A store over a scratch in-memory cache, activated the way `AppSession`
    /// activates the real one
    private func makeStore() async -> GenreBackdropStore {
        let suiteName = "LibraryCardViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = GenreBackdropStore(legacyDefaults: defaults)
        await store.activate(cache: ScopedCache(
            store: .makeInMemory(),
            scope: CacheScope(serverURL: URL(string: "https://demo.example.org")!, userID: "user-1"),
        ))
        return store
    }

    /// The handover `LibraryCardView` performs in its `.task`
    private func makeViewModel(store: GenreBackdropStore) -> LibraryCardViewModel {
        let viewModel = LibraryCardViewModel()
        viewModel.attach(store: store)
        return viewModel
    }

    /// An item that carries its own backdrop, so `backdropSlot(for:)` resolves.
    private func item(_ id: String) -> MediaItem {
        MediaItem(
            id: id,
            name: id,
            type: .movie,
            imageTags: ImageTags(backdrop: "tag", backdropBlurHash: "hash-\(id)"),
        )
    }

    private func page(_ ids: [String]) -> MediaItemPage {
        MediaItemPage(items: ids.map(item), startIndex: 0, totalRecordCount: ids.count)
    }

    /// One mounted card: the library and the view model that card owns.
    private struct Card {
        let library: Library
        let viewModel: LibraryCardViewModel
    }

    // MARK: - Sampling

    @Test("A library with artwork wears one of its items' backdrops")
    func samplesAnItemBackdrop() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a", "b", "c"]))]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)

        let selection = try #require(viewModel.selection)
        #expect(["a", "b", "c"].contains(selection.itemId))
        #expect(selection.imageType == .backdrop)
        #expect(selection.blurHash == "hash-\(selection.itemId)")

        // The URL must point at the sampled *item*, never at the library
        // itself: a library's own Primary image is a collage with its name
        // baked in, which is the whole reason the card samples (#138).
        let url = try #require(viewModel.backdropURL(client: client))
        #expect(url.path.contains("/Items/\(selection.itemId)/Images/Backdrop"))
        #expect(!url.path.contains(Self.movies.id))
    }

    @Test("The sample is scoped to the library, unfiltered, one page deep")
    func sampleRequestShape() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a"]))]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)

        let request = try #require(client.libraryItemsRequests.first)
        #expect(request.libraryId == Self.movies.id)
        #expect(request.itemTypes == [.movie])
        #expect(request.query.genres.isEmpty)
        #expect(request.startIndex == 0)
        #expect(request.limit == LibraryCardViewModel.pageSize)
    }

    @Test("A library with no items falls back to the themed wash")
    func emptyLibraryWearsTheWash() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page([]))]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)

        #expect(viewModel.selection == nil)
        #expect(viewModel.backdropURL(client: client) == nil)
        #expect(viewModel.blurHash == nil)
    }

    @Test("A library whose items carry no artwork falls back to the wash")
    func artlessLibraryWearsTheWash() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(MediaItemPage(
            items: [MediaItem(id: "bare", name: "bare", type: .movie)],
            startIndex: 0,
            totalRecordCount: 1,
        ))]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)

        #expect(viewModel.selection == nil)
        #expect(viewModel.backdropURL(client: client) == nil)
    }

    @Test("A failed sample leaves that card bare and says nothing about the others")
    func oneFailureDoesNotSinkTheGrid() async throws {
        // The grid's cards fetch concurrently, one view model each. A server
        // that refuses one library — permissions, a bad scan — must cost that
        // card its picture and nothing else.
        let shows = Library(id: "shows", name: "Series", collectionType: .tvshows)
        let broken = Library(id: "broken", name: "Broken", collectionType: .movies)

        // Everything the stub needs is built here, on the main actor, and
        // captured by value. `getLibraryItems` is a nonisolated async method,
        // so it calls this closure off the main actor — reaching back into the
        // suite for `page(_:)` or a static would be an isolation violation the
        // compiler waves through (the property's type isn't `@Sendable`) and
        // the runtime traps on, taking the whole test host with it.
        let moviesId = Self.movies.id
        let showsId = shows.id
        let moviesPage = page(["movie-a"])
        let showsPage = page(["show-a"])

        let client = MockJellyfinClient()
        client.libraryItemsHandler = { libraryId in
            switch libraryId {
            case moviesId: .success(moviesPage)
            case showsId: .success(showsPage)
            default: .failure(SampleFailure())
            }
        }

        let store = await makeStore()
        let cards = [Self.movies, shows, broken].map { Card(library: $0, viewModel: makeViewModel(store: store)) }
        // The failing library goes last only for readability: results are
        // keyed by library id, not served in request order, so no card's
        // outcome can depend on when it asked or on what another card got.
        // Loading them in sequence rather than in a task group costs nothing
        // — every card's view model is main-actor isolated, so a group would
        // serialize them here anyway.
        for card in cards {
            await card.viewModel.load(client: client, library: card.library)
        }

        #expect(try #require(cards[0].viewModel.selection).itemId == "movie-a")
        #expect(try #require(cards[1].viewModel.selection).itemId == "show-a")
        #expect(cards[2].viewModel.selection == nil)
        #expect(cards[2].viewModel.backdropURL(client: client) == nil)
    }

    @Test("A failed sample is retried on the card's next appearance")
    func failureRetriesNextTime() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.failure(SampleFailure())]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)
        #expect(viewModel.selection == nil)

        // A failure must not latch, or an offline launch costs the grid its
        // artwork for the rest of the session.
        client.libraryItemsPages = [.success(page(["a"]))]
        await viewModel.load(client: client, library: Self.movies)
        #expect(viewModel.selection?.itemId == "a")
    }

    // MARK: - Stability

    @Test("A settled card doesn't re-sample when it reappears")
    func settledCardDoesNotReshuffle() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a", "b", "c"]))]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)
        let first = viewModel.selection

        // The card's `.task` re-fires every time the grid scrolls it back or
        // the tab is returned to; the picture must not change under the
        // viewer, and must not cost a request.
        await viewModel.load(client: client, library: Self.movies)
        await viewModel.load(client: client, library: Self.movies)

        #expect(viewModel.selection == first)
        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("A remembered face is adopted without a request")
    func rememberedFaceCostsNothing() async {
        let store = await makeStore()
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a", "b", "c"]))]

        await makeViewModel(store: store).load(client: client, library: Self.movies)
        let remembered = store.selection(for: .library(id: Self.movies.id))
        #expect(remembered != nil)

        // A fresh card over the same store is the next launch, or a second
        // grid appearance after the first view model was torn down.
        let reborn = makeViewModel(store: store)
        await reborn.load(client: client, library: Self.movies)

        #expect(reborn.selection == remembered)
        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("A library's remembered face is keyed apart from its genres'")
    func libraryKeyDoesNotCollideWithGenreKeys() async {
        // Both cards can be on screen at once — Home's genre shelves and the
        // visionOS Libraries grid share one store — so a library's face must
        // not overwrite a genre's, in either direction.
        let store = await makeStore()
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["library-face"]))]
        await makeViewModel(store: store).load(client: client, library: Self.movies)

        client.libraryItemsPages = [.success(page(["genre-face"]))]
        let genreCard = GenreCardViewModel()
        genreCard.attach(store: store)
        await genreCard.load(client: client, library: Self.movies, genre: "Horror")

        #expect(store.selection(for: .library(id: Self.movies.id))?.itemId == "library-face")
        #expect(store.selection(for: GenreBackdropKey(libraryId: Self.movies.id, genre: "Horror"))?.itemId == "genre-face")
    }

    // MARK: - Repair

    @Test("Artwork that no longer renders is replaced once")
    func staleFaceIsRepaired() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["gone"]))]

        let viewModel = await makeViewModel(store: makeStore())
        await viewModel.load(client: client, library: Self.movies)
        #expect(viewModel.selection?.itemId == "gone")

        // The item was deleted server-side; the card's image load fails and
        // reports back.
        client.libraryItemsPages = [.success(page(["live"]))]
        await viewModel.backdropUnavailable(client: client, library: Self.movies)
        #expect(viewModel.selection?.itemId == "live")

        // Only once: a replacement that also fails must not spin. Pinning the
        // request count is the real assertion — without it a second fetch that
        // happened to re-pick "live" would pass while the card quietly spun.
        let requestsAfterRepair = client.libraryItemsRequests.count
        client.libraryItemsPages = [.success(page(["another"]))]
        await viewModel.backdropUnavailable(client: client, library: Self.movies)
        #expect(viewModel.selection?.itemId == "live")
        #expect(client.libraryItemsRequests.count == requestsAfterRepair)
    }

    @Test("A library that has lost all its artwork drops to the wash")
    func repairFallsBackToTheWash() async {
        let store = await makeStore()
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["only"]))]

        let viewModel = makeViewModel(store: store)
        await viewModel.load(client: client, library: Self.movies)

        // The sample comes back with the same broken face and nothing else —
        // the library genuinely has no other artwork to offer.
        await viewModel.backdropUnavailable(client: client, library: Self.movies)

        #expect(viewModel.selection == nil)
        #expect(store.selection(for: .library(id: Self.movies.id)) == nil)
    }
}

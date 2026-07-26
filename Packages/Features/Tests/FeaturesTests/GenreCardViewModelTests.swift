@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("GenreCardViewModel")
@MainActor
struct GenreCardViewModelTests {
    private static let library = Library(id: "movies", name: "Films", collectionType: .movies)
    private static let genre = "Horror"

    private func makeStore() -> GenreBackdropStore {
        let suiteName = "GenreCardViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GenreBackdropStore(defaults: defaults)
    }

    private var key: GenreBackdropKey {
        GenreBackdropKey(libraryId: Self.library.id, genre: Self.genre)
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

    private func page(_ ids: [String], startIndex: Int = 0, total: Int? = nil) -> MediaItemPage {
        MediaItemPage(items: ids.map(item), startIndex: startIndex, totalRecordCount: total ?? ids.count)
    }

    private func load(_ viewModel: GenreCardViewModel, _ client: MockJellyfinClient?) async {
        await viewModel.load(client: client, library: Self.library, genre: Self.genre)
    }

    private func cycle(_ viewModel: GenreCardViewModel, _ client: MockJellyfinClient?) async {
        await viewModel.cycle(client: client, library: Self.library, genre: Self.genre)
    }

    // MARK: - Cold load

    @Test("A cold card fetches one page and remembers what it picked")
    func coldLoadRemembers() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a", "b", "c"]))]
        let store = makeStore()

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)

        let selection = try #require(viewModel.selection)
        #expect(["a", "b", "c"].contains(selection.itemId))
        #expect(selection.imageType == .backdrop)
        #expect(selection.blurHash == "hash-\(selection.itemId)")
        #expect(store.selection(for: key) == selection)
        #expect(client.libraryItemsRequests.count == 1)
        #expect(client.libraryItemsRequests.first?.startIndex == 0)
        #expect(client.libraryItemsRequests.first?.query.genres == [Self.genre])
    }

    @Test("Only items that actually have a backdrop are eligible")
    func skipsArtlessItems() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(MediaItemPage(
            items: [MediaItem(id: "bare", name: "bare", type: .movie), item("art")],
            startIndex: 0,
            totalRecordCount: 2,
        ))]

        let viewModel = GenreCardViewModel(store: makeStore())
        await load(viewModel, client)

        #expect(try #require(viewModel.selection).itemId == "art")
    }

    @Test("A genre with no artwork stays a mesh-only card and remembers nothing")
    func artlessGenre() async {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(MediaItemPage(
            items: [MediaItem(id: "bare", name: "bare", type: .movie)],
            startIndex: 0,
            totalRecordCount: 1,
        ))]
        let store = makeStore()

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)

        #expect(viewModel.selection == nil)
        #expect(viewModel.backdropURL(client: client) == nil)
        #expect(store.selection(for: key) == nil)

        // Settled, though: a reappearance must not re-fetch within the card's
        // lifetime.
        await load(viewModel, client)
        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("A failed fetch doesn't latch — the next appearance retries")
    func failedFetchRetries() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .failure(APIError.networkError("offline")),
            .success(page(["a"])),
        ]

        let viewModel = GenreCardViewModel(store: makeStore())
        await load(viewModel, client)
        #expect(viewModel.selection == nil)

        await load(viewModel, client)
        #expect(try #require(viewModel.selection).itemId == "a")
    }

    // MARK: - Warm load

    @Test("A remembered choice is adopted without issuing a request")
    func warmLoadCostsNothing() async throws {
        // The acceptance criterion: returning to the shelf — across navigation
        // or across launches — shows the same backdrop and hits no endpoint.
        let store = makeStore()
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a", "b", "c"]))]

        let cold = GenreCardViewModel(store: store)
        await load(cold, client)
        let firstFace = try #require(cold.selection)
        client.libraryItemsRequests.removeAll()

        // A fresh view model over the same store is the card scrolling back in,
        // Home reappearing, or the app relaunching.
        let warm = GenreCardViewModel(store: store)
        await load(warm, client)

        #expect(warm.selection == firstFace)
        #expect(client.libraryItemsRequests.isEmpty)
    }

    @Test("The remembered choice rebuilds its URL against the current server")
    func urlRebuiltFromSelection() async {
        let store = makeStore()
        store.setSelection(
            GenreBackdropSelection(
                itemId: "item-1",
                imageTypeRawValue: ImageType.thumb.rawValue,
                blurHash: "hash",
                poolCount: 3,
            ),
            for: key,
        )
        let client = MockJellyfinClient()

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)

        #expect(viewModel.blurHash == "hash")
        #expect(
            viewModel.backdropURL(client: client)
                == client.getImageURL(itemId: "item-1", imageType: .thumb, maxWidth: nil, maxHeight: nil),
        )
    }

    @Test("An entry whose image type this build can't map back re-rolls")
    func unknownImageType() async throws {
        let store = makeStore()
        store.setSelection(
            GenreBackdropSelection(itemId: "item-1", imageTypeRawValue: "Hologram", blurHash: nil, poolCount: nil),
            for: key,
        )
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a"]))]

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)

        #expect(try #require(viewModel.selection).itemId == "a")
        #expect(client.libraryItemsRequests.count == 1)
    }

    // MARK: - Cycling

    @Test("Cycling fetches a fresh page at a random offset inside the pool")
    func cycleUsesRandomOffset() async throws {
        let store = makeStore()
        store.setSelection(
            GenreBackdropSelection(
                itemId: "old",
                imageTypeRawValue: ImageType.backdrop.rawValue,
                blurHash: nil,
                poolCount: 100,
            ),
            for: key,
        )
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a", "b"], total: 100))]

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)
        #expect(client.libraryItemsRequests.isEmpty)

        await cycle(viewModel, client)

        let request = try #require(client.libraryItemsRequests.first)
        #expect(client.libraryItemsRequests.count == 1)
        // A full page has to fit after the offset, so the last valid start is
        // total - pageSize.
        #expect((0 ... (100 - GenreCardViewModel.pageSize)).contains(request.startIndex))
        #expect(try ["a", "b"].contains(#require(viewModel.selection).itemId))
        #expect(store.selection(for: key) == viewModel.selection)
    }

    @Test("Cycling prefers a face other than the one on screen")
    func cyclePrefersADifferentItem() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(page(["a"])),
            .success(page(["a", "b"])),
        ]

        let viewModel = GenreCardViewModel(store: makeStore())
        await load(viewModel, client)
        #expect(try #require(viewModel.selection).itemId == "a")

        await cycle(viewModel, client)
        #expect(try #require(viewModel.selection).itemId == "b")
    }

    @Test("A single-item genre re-picks the same face rather than going bare")
    func cycleWithNothingElseToPick() async throws {
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["only"]))]

        let viewModel = GenreCardViewModel(store: makeStore())
        await load(viewModel, client)
        await cycle(viewModel, client)

        #expect(try #require(viewModel.selection).itemId == "only")
    }

    @Test("An offset past a shrunken genre falls back to the first page")
    func staleOffsetFallsBack() async throws {
        // The remembered pool count can outlive the items it counted; an empty
        // page is the server saying so. Driven through `roll` directly so the
        // offset is a fixture rather than a coin flip.
        let client = MockJellyfinClient()
        client.libraryItemsPages = [
            .success(MediaItemPage(items: [], startIndex: 400, totalRecordCount: 2)),
            .success(page(["a", "b"])),
        ]

        let viewModel = GenreCardViewModel(store: makeStore())
        let settled = await viewModel.roll(
            client: client,
            library: Self.library,
            genre: Self.genre,
            startIndex: 400,
        )

        #expect(settled)
        #expect(client.libraryItemsRequests.map(\.startIndex) == [400, 0])
        #expect(try ["a", "b"].contains(#require(viewModel.selection).itemId))
    }

    @Test("A pool no bigger than one page has no offset to pick")
    func randomStartIndexBounds() {
        let pageSize = GenreCardViewModel.pageSize
        #expect(GenreCardViewModel.randomStartIndex(poolCount: nil, pageSize: pageSize) == 0)
        #expect(GenreCardViewModel.randomStartIndex(poolCount: 0, pageSize: pageSize) == 0)
        #expect(GenreCardViewModel.randomStartIndex(poolCount: pageSize, pageSize: pageSize) == 0)
        for _ in 0 ..< 50 {
            let start = GenreCardViewModel.randomStartIndex(poolCount: pageSize + 1, pageSize: pageSize)
            #expect(start == 0 || start == 1)
        }
    }

    // MARK: - Stale repair

    @Test("A face that no longer renders is discarded and re-rolled")
    func staleSelectionRepairs() async throws {
        let store = makeStore()
        store.setSelection(
            GenreBackdropSelection(
                itemId: "deleted",
                imageTypeRawValue: ImageType.backdrop.rawValue,
                blurHash: nil,
                poolCount: 3,
            ),
            for: key,
        )
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a"]))]

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)
        #expect(try #require(viewModel.selection).itemId == "deleted")

        await viewModel.backdropUnavailable(client: client, library: Self.library, genre: Self.genre)

        #expect(try #require(viewModel.selection).itemId == "a")
        #expect(store.selection(for: key)?.itemId == "a")
        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("Repair happens once, so an unreachable server can't spin the card")
    func repairOnlyOnce() async {
        let store = makeStore()
        store.setSelection(
            GenreBackdropSelection(
                itemId: "deleted",
                imageTypeRawValue: ImageType.backdrop.rawValue,
                blurHash: nil,
                poolCount: 3,
            ),
            for: key,
        )
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["a"]))]

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)
        await viewModel.backdropUnavailable(client: client, library: Self.library, genre: Self.genre)
        await viewModel.backdropUnavailable(client: client, library: Self.library, genre: Self.genre)

        #expect(client.libraryItemsRequests.count == 1)
    }

    @Test("Nothing to repair when the card never had a face")
    func repairWithoutSelection() async {
        let client = MockJellyfinClient()
        let viewModel = GenreCardViewModel(store: makeStore())

        await viewModel.backdropUnavailable(client: client, library: Self.library, genre: Self.genre)

        #expect(client.libraryItemsRequests.isEmpty)
    }

    @Test("An unreachable server doesn't cost the card the face it had")
    func repairKeepsFaceWhenTheRollFails() async {
        // The same nil image reports "server is down" and "item is gone". An
        // offline launch must not re-roll every card on the way back up.
        let store = makeStore()
        let remembered = GenreBackdropSelection(
            itemId: "item-1",
            imageTypeRawValue: ImageType.backdrop.rawValue,
            blurHash: nil,
            poolCount: 3,
        )
        store.setSelection(remembered, for: key)
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.failure(APIError.networkError("offline"))]

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)
        await viewModel.backdropUnavailable(client: client, library: Self.library, genre: Self.genre)

        #expect(viewModel.selection == remembered)
        #expect(store.selection(for: key) == remembered)
    }

    @Test("A genre that has genuinely lost its artwork drops to a mesh-only card")
    func repairFallsBackToMeshOnly() async {
        let store = makeStore()
        store.setSelection(
            GenreBackdropSelection(
                itemId: "deleted",
                imageTypeRawValue: ImageType.backdrop.rawValue,
                blurHash: nil,
                poolCount: 1,
            ),
            for: key,
        )
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(MediaItemPage(
            items: [MediaItem(id: "bare", name: "bare", type: .movie)],
            startIndex: 0,
            totalRecordCount: 1,
        ))]

        let viewModel = GenreCardViewModel(store: store)
        await load(viewModel, client)
        await viewModel.backdropUnavailable(client: client, library: Self.library, genre: Self.genre)

        #expect(viewModel.selection == nil)
        #expect(store.selection(for: key) == nil)
    }
}

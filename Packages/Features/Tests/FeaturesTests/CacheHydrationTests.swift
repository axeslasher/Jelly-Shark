@testable import Features
import Foundation
import JellyfinKit
import Testing

// MARK: - Shared helpers

private func makeMovie(_ id: String) -> MediaItem {
    MediaItem(id: id, name: id, type: .movie, imageTags: ImageTags(backdrop: "tag"))
}

private func makeScopedCache() -> ScopedCache {
    ScopedCache(
        store: .makeInMemory(),
        scope: CacheScope(serverURL: URL(string: "https://example.com")!, userID: "user-1"),
    )
}

/// Poll until the condition holds (bounded), resolving background async
/// work without a fixed sleep.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Instant connect

@Suite("ServerConnectionViewModel instant connect")
@MainActor
struct InstantConnectTests {
    /// One restore scenario's moving parts, wired together the way
    /// `RootView` does it
    @MainActor
    final class Rig {
        let store = InMemorySessionStore()
        let client = MockJellyfinClient()
        let cache = MediaCacheStore.makeInMemory()
        let appSession = AppSession()
        let viewModel: ServerConnectionViewModel
        let scope: CacheScope

        init() {
            let saved = SavedSession(
                serverURL: URL(string: "https://demo.jellyfin.org/stable")!,
                userID: "user-1",
                accessToken: "token-1",
            )
            store.session = saved
            scope = CacheScope(serverURL: saved.serverURL, userID: saved.userID)
            let mock = client
            viewModel = ServerConnectionViewModel(
                sessionStore: store,
                makeClient: { _, _ in mock },
                cache: cache,
            )
            viewModel.attach(session: appSession)
        }

        func seedCache() async {
            await cache.write(
                [Library(id: "lib-1", name: "Movies", collectionType: .movies)],
                scope: scope,
                key: .libraries,
            )
            await cache.write(User(id: "user-1", name: "demo"), scope: scope, key: .currentUser)
        }
    }

    @Test("A cache hit publishes the session before validation resolves")
    func cacheHitPublishesImmediately() async {
        let rig = Rig()
        await rig.seedCache()
        let gate = AsyncGate()
        rig.client.fetchCurrentUserDelay = { try? await gate.wait() }
        rig.client.librariesResult = .success([Library(id: "lib-2", name: "Shows", collectionType: .tvshows)])

        await rig.viewModel.restoreSession()

        // Published from cache; the server hasn't answered yet
        #expect(rig.viewModel.state == .connected)
        #expect(rig.viewModel.isValidating)
        #expect(rig.viewModel.libraries.map(\.id) == ["lib-1"])
        #expect(rig.viewModel.connectedUser?.name == "demo")
        #expect(rig.viewModel.hasAttemptedRestore)
        #expect(rig.appSession.client != nil)
        #expect(rig.appSession.scopedCache != nil)

        await gate.open()
        await rig.viewModel.awaitValidation()

        // Validation refreshed the libraries from the server
        #expect(rig.viewModel.isValidating == false)
        #expect(rig.viewModel.state == .connected)
        #expect(rig.viewModel.libraries.map(\.id) == ["lib-2"])
    }

    @Test("A revoked token tears the provisional session down and purges its scope")
    func revokedTokenTearsDownAndPurges() async {
        let rig = Rig()
        await rig.seedCache()
        let gate = AsyncGate()
        rig.client.fetchCurrentUserDelay = { try? await gate.wait() }
        rig.client.fetchCurrentUserResult = .failure(APIError.unauthorized)

        await rig.viewModel.restoreSession()
        #expect(rig.viewModel.state == .connected)

        await gate.open()
        await rig.viewModel.awaitValidation()

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.viewModel.errorMessage != nil)
        #expect(rig.viewModel.libraries.isEmpty)
        #expect(rig.store.session == nil)
        #expect(rig.appSession.client == nil)
        #expect(await rig.cache.read([Library].self, scope: rig.scope, key: .libraries) == nil)
    }

    @Test("A transient validation failure leaves the session standing on cache")
    func transientFailureKeepsProvisionalSession() async {
        let rig = Rig()
        await rig.seedCache()
        rig.client.fetchCurrentUserResult = .failure(APIError.networkError("offline"))

        await rig.viewModel.restoreSession()
        await rig.viewModel.awaitValidation()

        #expect(rig.viewModel.state == .connected)
        #expect(rig.viewModel.isValidating == false)
        #expect(rig.viewModel.libraries.map(\.id) == ["lib-1"])
        #expect(rig.store.session != nil)
        #expect(rig.appSession.client != nil)
        #expect(await rig.cache.read([Library].self, scope: rig.scope, key: .libraries) != nil)
    }

    @Test("A cache miss runs the blocking validate-first flow")
    func cacheMissBlocksOnValidation() async {
        let rig = Rig()
        rig.client.librariesResult = .success([Library(id: "lib-1", name: "Movies")])

        await rig.viewModel.restoreSession()

        #expect(rig.viewModel.state == .connected)
        #expect(rig.viewModel.isValidating == false)
        #expect(rig.client.fetchCurrentUserCallCount == 1)
        #expect(rig.appSession.scopedCache != nil)
    }

    @Test("disconnect() purges the active scope and only that scope")
    func disconnectPurgesOnlyActiveScope() async {
        let rig = Rig()
        await rig.seedCache()
        let otherScope = CacheScope(serverURL: URL(string: "https://other.example.org")!, userID: "user-9")
        await rig.cache.write([Library(id: "lib-x", name: "Other")], scope: otherScope, key: .libraries)

        await rig.viewModel.restoreSession()
        await rig.viewModel.awaitValidation()
        await rig.viewModel.disconnect()

        #expect(rig.viewModel.state == .disconnected)
        #expect(rig.store.session == nil)
        #expect(await rig.cache.read([Library].self, scope: rig.scope, key: .libraries) == nil)
        #expect(await rig.cache.read([Library].self, scope: otherScope, key: .libraries) != nil)
    }
}

// MARK: - Home hydration

@Suite("HomeViewModel hydration")
@MainActor
struct HomeHydrationTests {
    private func makeSnapshot(
        resume: [MediaItem] = [],
        nextUp: [MediaItem] = [],
        shelves: [CachedHomeSnapshot.Shelf] = [],
        heroes: [MediaItem] = [],
    ) -> CachedHomeSnapshot {
        CachedHomeSnapshot(
            resume: resume,
            nextUp: nextUp,
            shelves: shelves,
            heroItems: heroes,
            episodePrimaryHeroIds: [],
            seriesLastPlayedDates: [:],
        )
    }

    @Test("A hydrated Home reveals before the network settles")
    func hydratedHomeRevealsBeforeNetwork() async {
        let cache = makeScopedCache()
        await cache.write(
            makeSnapshot(resume: [makeMovie("cached-r")], heroes: [makeMovie("cached-h")]),
            key: .homeSnapshot,
        )
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([makeMovie("fresh-r")])
        let gate = AsyncGate()
        client.latestItemsDelay = { try? await gate.wait() }

        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [], cache: cache)
        let load = Task { await viewModel.load() }

        // The resume lane reconciles to fresh content while the hero's
        // source fetch is still gated — and the page is already revealed.
        await waitUntil { viewModel.resumeItems.map(\.id) == ["fresh-r"] }
        #expect(viewModel.isInitialLoading == false)
        #expect(viewModel.heroItems.map(\.id) == ["cached-h"])

        await gate.open()
        await load.value
        #expect(viewModel.isInitialLoading == false)
    }

    @Test("Every fetch failing keeps the hydrated page whole")
    func offlineKeepsHydratedContent() async {
        let cache = makeScopedCache()
        let shelf = CachedHomeSnapshot.Shelf(
            library: Library(id: "movies", name: "Movies", collectionType: .movies),
            items: [makeMovie("cached-s")],
        )
        await cache.write(
            makeSnapshot(
                resume: [makeMovie("cached-r")],
                nextUp: [makeMovie("cached-n")],
                shelves: [shelf],
                heroes: [makeMovie("cached-h")],
            ),
            key: .homeSnapshot,
        )
        let client = MockJellyfinClient()
        client.resumeItemsResult = .failure(APIError.networkError("offline"))
        client.nextUpItemsResult = .failure(APIError.networkError("offline"))
        client.latestItemsHandler = { _ in .failure(APIError.networkError("offline")) }
        client.recentlyPlayedEpisodesResult = .failure(APIError.networkError("offline"))

        let viewModel = HomeViewModel()
        viewModel.attach(
            client: client,
            libraries: [Library(id: "movies", name: "Movies", collectionType: .movies)],
            cache: cache,
        )
        await viewModel.load()

        #expect(viewModel.resumeItems.map(\.id) == ["cached-r"])
        #expect(viewModel.nextUpItems.map(\.id) == ["cached-n"])
        #expect(viewModel.latestShelves.flatMap(\.items).map(\.id) == ["cached-s"])
        #expect(viewModel.heroItems.map(\.id) == ["cached-h"])
        #expect(viewModel.isInitialLoading == false)
        #expect(viewModel.resumeStatus == .loaded)
        #expect(viewModel.nextUpStatus == .loaded)
        #expect(viewModel.latestStatus == .loaded)

        // The failure re-armed the load: the next appearance refetches and
        // reconciles to server truth.
        client.resumeItemsResult = .success([makeMovie("fresh-r")])
        client.nextUpItemsResult = .success([])
        client.latestItemsHandler = { _ in .success([]) }
        client.recentlyPlayedEpisodesResult = .success([])
        await viewModel.load()
        #expect(viewModel.resumeItems.map(\.id) == ["fresh-r"])
    }

    @Test("A successful load writes the snapshot a fresh instance hydrates from")
    func snapshotRoundTripsIntoAFreshInstance() async {
        let cache = makeScopedCache()
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([makeMovie("r-1")])

        let first = HomeViewModel()
        first.attach(client: client, libraries: [], cache: cache)
        await first.load()

        // "Second launch": a fresh view model, same cache, dead network.
        let offlineClient = MockJellyfinClient()
        offlineClient.resumeItemsResult = .failure(APIError.networkError("offline"))
        offlineClient.nextUpItemsResult = .failure(APIError.networkError("offline"))
        offlineClient.latestItemsHandler = { _ in .failure(APIError.networkError("offline")) }
        offlineClient.recentlyPlayedEpisodesResult = .failure(APIError.networkError("offline"))

        let second = HomeViewModel()
        second.attach(client: offlineClient, libraries: [], cache: cache)
        await second.load()

        #expect(second.resumeItems.map(\.id) == ["r-1"])
        #expect(second.isInitialLoading == false)
    }
}

// MARK: - Library grid hydration

@Suite("LibraryItemsViewModel hydration")
@MainActor
struct LibraryHydrationTests {
    private func page(_ ids: [String], total: Int? = nil) -> MediaItemPage {
        MediaItemPage(items: ids.map(makeMovie), startIndex: 0, totalRecordCount: total ?? ids.count)
    }

    @Test("The default browse hydrates, then reconciles to the fresh page")
    func defaultBrowseHydratesThenReconciles() async {
        let cache = makeScopedCache()
        await cache.write(page(["cached-1", "cached-2"]), key: .libraryFirstPage(libraryID: nil))
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["fresh-1"]))]
        let gate = AsyncGate()
        client.libraryItemsDelay = { try? await gate.wait() }

        let viewModel = LibraryItemsViewModel()
        viewModel.attach(client: client, cache: cache)
        let load = Task { await viewModel.loadInitial() }

        await waitUntil { viewModel.items.isEmpty == false }
        // Rendered from cache while the fresh page 0 is still gated
        #expect(viewModel.items.map(\.id) == ["cached-1", "cached-2"])
        #expect(viewModel.state == .loaded)

        await gate.open()
        await load.value
        #expect(viewModel.items.map(\.id) == ["fresh-1"])
    }

    @Test("A filtered seed query never consults the cache")
    func filteredSeedSkipsCache() async {
        let cache = makeScopedCache()
        await cache.write(page(["cached-1"]), key: .libraryFirstPage(libraryID: nil))
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["fresh-1"]))]
        let gate = AsyncGate()
        client.libraryItemsDelay = { try? await gate.wait() }

        let viewModel = LibraryItemsViewModel()
        viewModel.attach(client: client, initialQuery: LibraryQuery(favoritesOnly: true), cache: cache)
        let load = Task { await viewModel.loadInitial() }

        // Give a (wrong) hydration every chance to land before asserting it
        // didn't: the page fetch is gated, so only hydration could populate
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(viewModel.items.isEmpty)
        #expect(viewModel.state == .loading)

        await gate.open()
        await load.value
        #expect(viewModel.items.map(\.id) == ["fresh-1"])
    }

    @Test("Pagination is held until the hydrated page's refresh lands")
    func paginationHeldDuringHydratedRefresh() async {
        let cache = makeScopedCache()
        await cache.write(page(["cached-1", "cached-2"], total: 3), key: .libraryFirstPage(libraryID: nil))
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.success(page(["fresh-1", "fresh-2"], total: 3))]
        let gate = AsyncGate()
        client.libraryItemsDelay = { try? await gate.wait() }

        let viewModel = LibraryItemsViewModel()
        viewModel.attach(client: client, cache: cache)
        let load = Task { await viewModel.loadInitial() }
        await waitUntil { viewModel.items.isEmpty == false }

        // hasMore is true off the cached page, but this paging attempt must
        // be swallowed. Asserted after quiescence below, not here — reading
        // the request log mid-flight races loadInitial's own page-0 fetch.
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items[1])

        client.libraryItemsDelay = nil
        await gate.open()
        await load.value
        await viewModel.awaitPendingLoad()

        // Only page 0 was ever requested: a wrongly-fired pagination would
        // show as a second request and as spliced orderings in the grid
        #expect(client.libraryItemsRequests.count == 1)
        #expect(viewModel.items.map(\.id) == ["fresh-1", "fresh-2"])

        // With the fresh page landed, pagination resumes from its count
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items[1])
        await viewModel.awaitPendingLoad()
        #expect(client.libraryItemsRequests.count == 2)
        #expect(client.libraryItemsRequests.last?.startIndex == 2)
    }

    @Test("A failed refresh keeps the hydrated grid and retries next appearance")
    func refreshFailureKeepsHydratedGrid() async {
        let cache = makeScopedCache()
        await cache.write(page(["cached-1"]), key: .libraryFirstPage(libraryID: nil))
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.failure(APIError.networkError("offline"))]

        let viewModel = LibraryItemsViewModel()
        viewModel.attach(client: client, cache: cache)
        await viewModel.loadInitial()

        #expect(viewModel.items.map(\.id) == ["cached-1"])
        #expect(viewModel.state == .loaded)

        // The retry was re-armed even though the state never reached .failed
        client.libraryItemsPages = [.success(page(["fresh-1"]))]
        await viewModel.loadInitial()
        #expect(viewModel.items.map(\.id) == ["fresh-1"])
    }

    @Test("A failed refresh keeps pagination held against the stale page")
    func refreshFailureHoldsPagination() async {
        let cache = makeScopedCache()
        await cache.write(page(["cached-1", "cached-2"], total: 3), key: .libraryFirstPage(libraryID: nil))
        let client = MockJellyfinClient()
        client.libraryItemsPages = [.failure(APIError.networkError("offline"))]

        let viewModel = LibraryItemsViewModel()
        viewModel.attach(client: client, cache: cache)
        await viewModel.loadInitial()
        #expect(viewModel.items.map(\.id) == ["cached-1", "cached-2"])

        // hasMore is true off the cached total, but appending the server's
        // current page 1 to the stale cached page 0 would splice two
        // orderings — the hold must survive the failed refresh
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items[1])
        await viewModel.awaitPendingLoad()
        #expect(client.libraryItemsRequests.count == 1)
    }
}

// MARK: - Media detail hydration

@Suite("MediaDetailViewModel hydration")
@MainActor
struct MediaDetailHydrationTests {
    private let stub = MediaItem(id: "m-1", name: "Stub", type: .movie)

    private var cachedDetail: MediaItem {
        MediaItem(
            id: "m-1",
            name: "Cached",
            type: .movie,
            overview: "cached overview",
            people: [CastMember(id: "p-1", name: "Director Person", kind: "Director")],
        )
    }

    @Test("The cached detail enriches the page before the fetch resolves")
    func cachedDetailEnrichesFirstFrame() async {
        let cache = makeScopedCache()
        await cache.write(cachedDetail, key: .mediaDetail(itemID: "m-1"))
        let client = MockJellyfinClient()
        client.mediaItemsById["m-1"] = MediaItem(id: "m-1", name: "Fresh", type: .movie)
        let gate = AsyncGate()
        client.mediaItemDelay = { try? await gate.wait() }

        let viewModel = MediaDetailViewModel()
        viewModel.attach(client: client, item: stub, cache: cache)
        let load = Task { await viewModel.load() }

        await waitUntil { viewModel.detailedItem != nil }
        // Hydrated while the network fetch is still gated; credits derived
        #expect(viewModel.detailedItem?.name == "Cached")
        #expect(viewModel.directors.isEmpty == false)
        #expect(viewModel.status == .loading)

        await gate.open()
        await load.value
        #expect(viewModel.detailedItem?.name == "Fresh")
        #expect(viewModel.status == .loaded)
    }

    @Test("A failed fetch keeps the hydrated detail on screen")
    func fetchFailureKeepsHydratedDetail() async {
        let cache = makeScopedCache()
        await cache.write(cachedDetail, key: .mediaDetail(itemID: "m-1"))
        let client = MockJellyfinClient()
        client.mediaItemFailureIds = ["m-1"]

        let viewModel = MediaDetailViewModel()
        viewModel.attach(client: client, item: stub, cache: cache)
        await viewModel.load()

        #expect(viewModel.detailedItem?.name == "Cached")
        if case .failed = viewModel.status {} else {
            Issue.record("expected .failed, got \(viewModel.status)")
        }
    }
}

import Foundation
@testable import JellyfinKit
import Testing

@Suite("CachingJellyfinClient")
struct CachingJellyfinClientTests {
    let store = MediaCacheStore.makeInMemory()
    let stub: StubJellyfinClient
    let client: CachingJellyfinClient
    let scope: CacheScope
    let user = User(id: "user-1", name: "Justin")

    init() {
        stub = StubJellyfinClient()
        stub.currentUser = user
        client = CachingJellyfinClient(wrapping: stub, cache: store)
        scope = CacheScope(serverURL: stub.serverURL, userID: user.id)
    }

    private func item(_ id: String, userData: UserData? = nil) -> MediaItem {
        MediaItem(id: id, name: "Item \(id)", type: .movie, userData: userData)
    }

    // MARK: - Blob writes

    @Test func fetchCurrentUserPersistsTheUser() async throws {
        stub.currentUser = nil
        stub.userResult = user
        _ = try await client.fetchCurrentUser()
        #expect(await store.read(User.self, scope: scope, key: .currentUser) == user)
    }

    @Test func authenticatePersistsTheUser() async throws {
        stub.currentUser = nil
        stub.userResult = user
        _ = try await client.authenticate(username: "justin", password: "pw")
        #expect(await store.read(User.self, scope: scope, key: .currentUser) == user)
    }

    @Test func getLibrariesPersistsTheList() async throws {
        let libraries = [Library(id: "lib-1", name: "Films", collectionType: .movies)]
        stub.librariesResult = libraries
        _ = try await client.getLibraries()
        #expect(await store.read([Library].self, scope: scope, key: .libraries) == libraries)
    }

    @Test func unauthenticatedFetchesWriteNothing() async throws {
        stub.currentUser = nil
        stub.librariesResult = [Library(id: "lib-1", name: "Films")]
        _ = try await client.getLibraries()
        #expect(await store.read([Library].self, scope: scope, key: .libraries) == nil)
    }

    @Test func getMediaItemPersistsDetailAndIngestsUserData() async throws {
        let detail = item("m-1", userData: UserData(isFavorite: true))
        stub.mediaItemResult = detail
        _ = try await client.getMediaItem(itemId: "m-1")
        #expect(await store.read(MediaItem.self, scope: scope, key: .mediaDetail(itemID: "m-1")) == detail)
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]?.isFavorite == true)
    }

    // MARK: - Library first page

    @Test func defaultQueryFirstPageIsCached() async throws {
        let page = MediaItemPage(
            items: [item("m-1", userData: UserData(played: true))],
            startIndex: 0,
            totalRecordCount: 120,
        )
        stub.libraryItemsResult = page
        _ = try await client.getLibraryItems(
            libraryId: "lib-1",
            itemTypes: [.movie],
            query: LibraryQuery(),
            limit: 100,
            startIndex: 0,
        )
        let cached = await store.read(MediaItemPage.self, scope: scope, key: .libraryFirstPage(libraryID: "lib-1"))
        #expect(cached?.items == page.items)
        #expect(cached?.totalRecordCount == 120)
        // The page's user data was ingested too
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]?.played == true)
    }

    @Test func filteredSortedAndLaterPagesAreNotCached() async throws {
        stub.libraryItemsResult = MediaItemPage(
            items: [item("m-1", userData: UserData(played: true))],
            startIndex: 0,
            totalRecordCount: 1,
        )
        let key = CacheSnapshotKey.libraryFirstPage(libraryID: "lib-1")

        _ = try await client.getLibraryItems(
            libraryId: "lib-1",
            itemTypes: [.movie],
            query: LibraryQuery(favoritesOnly: true),
            limit: 100,
            startIndex: 0,
        )
        #expect(await store.read(MediaItemPage.self, scope: scope, key: key) == nil)

        _ = try await client.getLibraryItems(
            libraryId: "lib-1",
            itemTypes: [.movie],
            query: LibraryQuery(sort: .dateAdded, direction: .descending),
            limit: 100,
            startIndex: 0,
        )
        #expect(await store.read(MediaItemPage.self, scope: scope, key: key) == nil)

        _ = try await client.getLibraryItems(
            libraryId: "lib-1",
            itemTypes: [.movie],
            query: LibraryQuery(),
            limit: 100,
            startIndex: 100,
        )
        #expect(await store.read(MediaItemPage.self, scope: scope, key: key) == nil)

        // Every one of those responses still fed the user-state table
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]?.played == true)
    }

    // MARK: - User-data ingestion from list fetches

    @Test func listFetchesIngestUserData() async throws {
        stub.resumeItemsResult = [item("r-1", userData: UserData(playbackPositionTicks: 900))]
        stub.episodesResult = [item("e-1", userData: UserData(played: true)), item("e-2")]
        _ = try await client.getResumeItems(limit: 10)
        _ = try await client.getEpisodes(seriesId: "series-1", seasonId: nil)

        let states = await store.userStates(scope: scope, itemIDs: ["r-1", "e-1", "e-2"])
        #expect(states["r-1"]?.playbackPositionTicks == 900)
        #expect(states["e-1"]?.played == true)
        // No userData on the response means no row, not a zeroed row
        #expect(states["e-2"] == nil)
    }

    // MARK: - Acknowledged mutations

    @Test func markPlayedUpdatesStateAndClearsPosition() async throws {
        await store.ingestServerUserData(
            scope: scope,
            items: [item("m-1", userData: UserData(playbackPositionTicks: 900, isFavorite: true))],
        )
        try await client.markPlayed(itemId: "m-1")
        let state = await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]
        #expect(state == CachedUserStateValue(played: true, isFavorite: true))
        #expect(stub.markPlayedCalls == ["m-1"])
    }

    @Test func markUnplayedClearsPlayedAndPosition() async throws {
        await store.ingestServerUserData(
            scope: scope,
            items: [item("m-1", userData: UserData(playbackPositionTicks: 900, played: true))],
        )
        try await client.markUnplayed(itemId: "m-1")
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"] == CachedUserStateValue())
    }

    @Test func favoriteTogglesUpdateState() async throws {
        try await client.markFavorite(itemId: "m-1")
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]?.isFavorite == true)
        try await client.unmarkFavorite(itemId: "m-1")
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]?.isFavorite == false)
    }

    @Test func failedMutationLeavesStateUntouched() async {
        await store.ingestServerUserData(scope: scope, items: [item("m-1", userData: UserData(played: false))])
        stub.markError = StubError()
        await #expect(throws: StubError.self) {
            try await client.markPlayed(itemId: "m-1")
        }
        #expect(await store.userStates(scope: scope, itemIDs: ["m-1"])["m-1"]?.played == false)
    }
}

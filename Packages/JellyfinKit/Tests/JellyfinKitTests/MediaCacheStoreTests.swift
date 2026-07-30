import Foundation
@testable import JellyfinKit
import Testing

// MARK: - Helpers

private func makeScope(server: String = "https://demo.example.org", user: String = "user-1") -> CacheScope {
    CacheScope(serverURL: URL(string: server)!, userID: user)
}

private func makeItem(id: String, userData: UserData? = nil) -> MediaItem {
    MediaItem(id: id, name: "Item \(id)", type: .movie, userData: userData)
}

private let sampleLibraries = [
    Library(id: "lib-1", name: "Films", collectionType: .movies, childCount: 42),
    Library(id: "lib-2", name: "Shows", collectionType: .tvshows),
]

@Suite("CacheScope")
struct CacheScopeTests {
    @Test func normalizesCosmeticServerVariants() {
        let canonical = CacheScope(serverURL: URL(string: "https://demo.example.org")!, userID: "u")
        #expect(CacheScope(serverURL: URL(string: "HTTPS://Demo.Example.ORG:443/")!, userID: "u") == canonical)
        #expect(CacheScope(serverURL: URL(string: "https://demo.example.org/")!, userID: "u") == canonical)

        let httpCanonical = CacheScope(serverURL: URL(string: "http://nas.local/jellyfin")!, userID: "u")
        #expect(CacheScope(serverURL: URL(string: "http://NAS.local:80/jellyfin/")!, userID: "u") == httpCanonical)
    }

    @Test func distinctServersAndUsersStayDistinct() {
        let base = makeScope()
        #expect(makeScope(user: "user-2") != base)
        #expect(makeScope(server: "https://other.example.org") != base)
        // A non-default port is part of the server's identity
        #expect(makeScope(server: "https://demo.example.org:8920") != base)
    }
}

@Suite("MediaCacheStore")
struct MediaCacheStoreTests {
    let store = MediaCacheStore.makeInMemory()
    let scope = makeScope()

    @Test func blobRoundTripsPerKey() async {
        let user = User(id: "user-1", name: "Justin")
        let detail = makeItem(id: "m-1", userData: UserData(isFavorite: true))
        let page = MediaItemPage(items: [makeItem(id: "m-2")], startIndex: 0, totalRecordCount: 7)

        await store.write(user, scope: scope, key: .currentUser)
        await store.write(sampleLibraries, scope: scope, key: .libraries)
        await store.write(detail, scope: scope, key: .mediaDetail(itemID: "m-1"))
        await store.write(page, scope: scope, key: .libraryFirstPage(libraryID: "lib-1"))

        #expect(await store.read(User.self, scope: scope, key: .currentUser) == user)
        #expect(await store.read([Library].self, scope: scope, key: .libraries) == sampleLibraries)
        #expect(await store.read(MediaItem.self, scope: scope, key: .mediaDetail(itemID: "m-1")) == detail)
        let readPage = await store.read(MediaItemPage.self, scope: scope, key: .libraryFirstPage(libraryID: "lib-1"))
        #expect(readPage?.items == page.items)
        #expect(readPage?.totalRecordCount == 7)
        // The scoped and unscoped grids are different keys
        #expect(await store.read(MediaItemPage.self, scope: scope, key: .libraryFirstPage(libraryID: nil)) == nil)
    }

    @Test func homeSnapshotRoundTrips() async {
        let snapshot = CachedHomeSnapshot(
            resume: [makeItem(id: "r-1")],
            nextUp: [makeItem(id: "n-1")],
            shelves: [.init(library: sampleLibraries[0], items: [makeItem(id: "s-1")])],
            heroItems: [makeItem(id: "h-1")],
            episodePrimaryHeroIds: ["h-1"],
            seriesLastPlayedDates: ["series-1": Date(timeIntervalSince1970: 1000)],
        )
        await store.write(snapshot, scope: scope, key: .homeSnapshot)

        let read = await store.read(CachedHomeSnapshot.self, scope: scope, key: .homeSnapshot)
        #expect(read?.resume == snapshot.resume)
        #expect(read?.shelves.first?.library == sampleLibraries[0])
        #expect(read?.heroItems == snapshot.heroItems)
        #expect(read?.seriesLastPlayedDates == snapshot.seriesLastPlayedDates)
    }

    @Test func writeReplacesPreviousBlob() async {
        await store.write([sampleLibraries[0]], scope: scope, key: .libraries)
        await store.write([sampleLibraries[1]], scope: scope, key: .libraries)
        #expect(await store.read([Library].self, scope: scope, key: .libraries) == [sampleLibraries[1]])
    }

    @Test func undecodableBlobIsAMissAndIsDeleted() async {
        await store.write("junk", scope: scope, key: .libraries)
        #expect(await store.read([Library].self, scope: scope, key: .libraries) == nil)
        // The row was deleted on the failed decode, not left to fail again
        #expect(await store.read(String.self, scope: scope, key: .libraries) == nil)
    }

    @Test func scopesAreIsolatedAndPurgeScoped() async {
        let other = makeScope(user: "user-2")
        await store.write(sampleLibraries, scope: scope, key: .libraries)
        await store.write(sampleLibraries, scope: other, key: .libraries)
        await store.ingestServerUserData(scope: scope, items: [makeItem(id: "a", userData: UserData(played: true))])
        await store.ingestServerUserData(scope: other, items: [makeItem(id: "a", userData: UserData(played: true))])

        #expect(await store.read([Library].self, scope: other, key: .libraries) != nil)

        await store.purge(scope: scope)

        #expect(await store.read([Library].self, scope: scope, key: .libraries) == nil)
        #expect(await store.userStates(scope: scope, itemIDs: ["a"]).isEmpty)
        // The sibling scope is untouched
        #expect(await store.read([Library].self, scope: other, key: .libraries) == sampleLibraries)
        #expect(await store.userStates(scope: other, itemIDs: ["a"])["a"]?.played == true)
    }

    @Test func ingestRecordsAndMergesServerUserData() async {
        await store.ingestServerUserData(scope: scope, items: [
            makeItem(id: "a", userData: UserData(playbackPositionTicks: 500, isFavorite: true)),
            makeItem(id: "b", userData: UserData(played: true)),
        ])
        var states = await store.userStates(scope: scope, itemIDs: ["a", "b"])
        #expect(states["a"] == CachedUserStateValue(isFavorite: true, playbackPositionTicks: 500))
        #expect(states["b"] == CachedUserStateValue(played: true))

        // A later report overwrites: server truth is last-write-wins here
        await store.ingestServerUserData(scope: scope, items: [
            makeItem(id: "a", userData: UserData(played: true)),
        ])
        states = await store.userStates(scope: scope, itemIDs: ["a"])
        #expect(states["a"] == CachedUserStateValue(played: true))
    }

    @Test func ingestSkipsItemsWithoutUserDataOrRealId() async {
        await store.ingestServerUserData(scope: scope, items: [
            makeItem(id: "bare"),
            makeItem(id: "", userData: UserData(played: true)),
        ])
        #expect(await store.userStates(scope: scope, itemIDs: ["bare", ""]).isEmpty)
    }

    @Test func setUserStateCreatesAndMutates() async {
        await store.setUserState(scope: scope, itemID: "fresh") { $0.isFavorite = true }
        #expect(await store.userStates(scope: scope, itemIDs: ["fresh"])["fresh"]?.isFavorite == true)

        await store.ingestServerUserData(
            scope: scope,
            items: [makeItem(id: "seen", userData: UserData(playbackPositionTicks: 900, isFavorite: true))],
        )
        await store.setUserState(scope: scope, itemID: "seen") { state in
            state.played = true
            state.playbackPositionTicks = nil
        }
        let state = await store.userStates(scope: scope, itemIDs: ["seen"])["seen"]
        // The untouched field survives the mutation
        #expect(state == CachedUserStateValue(played: true, isFavorite: true))
    }

    @Test func detailPruningKeepsTheNewest() async {
        for index in 1 ... 5 {
            await store.write(makeItem(id: "m-\(index)"), scope: scope, key: .mediaDetail(itemID: "m-\(index)"))
        }
        // Detail rows are pruned; the fixed-key blob families are not
        await store.write(sampleLibraries, scope: scope, key: .libraries)

        await store.purgeStaleDetails(scope: scope, keepingNewest: 3)

        #expect(await store.read(MediaItem.self, scope: scope, key: .mediaDetail(itemID: "m-1")) == nil)
        #expect(await store.read(MediaItem.self, scope: scope, key: .mediaDetail(itemID: "m-2")) == nil)
        for index in 3 ... 5 {
            #expect(await store.read(MediaItem.self, scope: scope, key: .mediaDetail(itemID: "m-\(index)")) != nil)
        }
        #expect(await store.read([Library].self, scope: scope, key: .libraries) != nil)
    }
}

@Suite("MediaCacheStore persistence")
struct MediaCacheStorePersistenceTests {
    /// A scratch on-disk home for one test, torn down afterwards
    private func withScratchStore(
        _ body: (URL, UserDefaults) async throws -> Void,
    ) async rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MediaCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "com.jellyshark.tests.cache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(directory, defaults)
    }

    @Test func cacheSurvivesARestartOnTheSameVersion() async {
        await withScratchStore { directory, defaults in
            let scope = makeScope()
            let first = MediaCacheStore.makePersistent(directory: directory, defaults: defaults, version: 1)
            await first.write(sampleLibraries, scope: scope, key: .libraries)
            await first.ingestServerUserData(scope: scope, items: [makeItem(id: "a", userData: UserData(played: true))])

            let second = MediaCacheStore.makePersistent(directory: directory, defaults: defaults, version: 1)
            #expect(await second.read([Library].self, scope: scope, key: .libraries) == sampleLibraries)
            #expect(await second.userStates(scope: scope, itemIDs: ["a"])["a"]?.played == true)
        }
    }

    @Test func versionBumpWipesTheStore() async {
        await withScratchStore { directory, defaults in
            let scope = makeScope()
            let old = MediaCacheStore.makePersistent(directory: directory, defaults: defaults, version: 1)
            await old.write(sampleLibraries, scope: scope, key: .libraries)

            let bumped = MediaCacheStore.makePersistent(directory: directory, defaults: defaults, version: 2)
            #expect(await bumped.read([Library].self, scope: scope, key: .libraries) == nil)
            // The new store works — the wipe was a reset, not a failure
            await bumped.write(sampleLibraries, scope: scope, key: .libraries)
            #expect(await bumped.read([Library].self, scope: scope, key: .libraries) == sampleLibraries)
        }
    }

    @Test func corruptStoreFileIsDestroyedAndRebuilt() async throws {
        try await withScratchStore { directory, defaults in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storeURL = directory.appending(path: "MediaCache.store")
            try Data("not a database".utf8).write(to: storeURL)
            defaults.set(1, forKey: MediaCacheStore.versionDefaultsKey)

            let scope = makeScope()
            let store = MediaCacheStore.makePersistent(directory: directory, defaults: defaults, version: 1)
            await store.write(sampleLibraries, scope: scope, key: .libraries)
            #expect(await store.read([Library].self, scope: scope, key: .libraries) == sampleLibraries)
        }
    }

    @Test func unusableDirectoryFallsBackToAnInertInMemoryStore() async {
        let defaults = UserDefaults(suiteName: "com.jellyshark.tests.cache.inert")!
        defer { defaults.removePersistentDomain(forName: "com.jellyshark.tests.cache.inert") }

        // /dev/null can never become a directory, so both creation attempts fail
        let store = MediaCacheStore.makePersistent(
            directory: URL(filePath: "/dev/null/MediaCache"),
            defaults: defaults,
            version: 1,
        )
        let scope = makeScope()
        await store.write(sampleLibraries, scope: scope, key: .libraries)
        #expect(await store.read([Library].self, scope: scope, key: .libraries) == sampleLibraries)
    }
}

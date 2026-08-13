@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("GenreBackdropStore")
@MainActor
struct GenreBackdropStoreTests {
    private static let serverURL = URL(string: "https://demo.example.org")!

    /// A scratch in-memory cache per test, so nothing leaks between them.
    /// One `MediaCacheStore` can hold several scopes, which is what makes the
    /// profile-switch cases below testable.
    private func makeCache(
        store: MediaCacheStore = .makeInMemory(),
        userID: String = "user-1",
    ) -> ScopedCache {
        ScopedCache(store: store, scope: CacheScope(serverURL: Self.serverURL, userID: userID))
    }

    private func makeStore(_ cache: ScopedCache) async -> GenreBackdropStore {
        let store = GenreBackdropStore()
        await store.activate(cache: cache)
        return store
    }

    private func selection(_ itemId: String) -> GenreBackdropSelection {
        GenreBackdropSelection(
            itemId: itemId,
            imageTypeRawValue: ImageType.backdrop.rawValue,
            blurHash: "hash",
            poolCount: 40,
        )
    }

    /// The persisted map, or nil on a miss
    private func stored(in cache: ScopedCache) async -> [String: GenreBackdropSelection]? {
        await cache.read([String: GenreBackdropSelection].self, key: .genreBackdrops)
    }

    /// Poll until the fire-and-forget write lands (bounded)
    private func waitForCache(_ condition: () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Reading and writing

    @Test("Nothing is remembered before anything is chosen")
    func emptyByDefault() async {
        let store = await makeStore(makeCache())
        #expect(store.selection(for: GenreBackdropKey(libraryId: "movies", genre: "Horror")) == nil)
    }

    @Test("A choice survives a relaunch")
    func persistsAcrossInstances() async {
        // The whole point of the store: `@State` dies with the view, so only a
        // trip through the cache keeps a genre's face stable across launches.
        let cache = makeCache()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

        await makeStore(cache).setSelection(selection("item-1"), for: key)
        await waitForCache { await stored(in: cache)?[key.storageKey] != nil }

        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: key) == selection("item-1"))
    }

    @Test("Clearing a choice removes it, including from the cache")
    func clearing() async {
        let cache = makeCache()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

        let store = await makeStore(cache)
        store.setSelection(selection("item-1"), for: key)
        await waitForCache { await stored(in: cache)?[key.storageKey] != nil }
        store.setSelection(nil, for: key)
        await waitForCache { await stored(in: cache)?[key.storageKey] == nil }

        #expect(store.selection(for: key) == nil)
        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: key) == nil)
    }

    @Test("The same genre in two libraries keeps two faces")
    func scopedPerLibrary() async {
        let store = await makeStore(makeCache())
        let movies = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        let fourK = GenreBackdropKey(libraryId: "4k-movies", genre: "Horror")

        store.setSelection(selection("item-1"), for: movies)
        store.setSelection(selection("item-2"), for: fourK)

        #expect(store.selection(for: movies)?.itemId == "item-1")
        #expect(store.selection(for: fourK)?.itemId == "item-2")
    }

    @Test("A genre name containing a separator can't collide across libraries")
    func separatorInGenreName() async {
        // "Action/Adventure" is a real Jellyfin genre, so the key can't be
        // joined on any character a genre name might contain.
        let store = await makeStore(makeCache())
        let first = GenreBackdropKey(libraryId: "a", genre: "b/c")
        let second = GenreBackdropKey(libraryId: "a/b", genre: "c")

        store.setSelection(selection("item-1"), for: first)
        store.setSelection(selection("item-2"), for: second)

        #expect(store.selection(for: first)?.itemId == "item-1")
        #expect(store.selection(for: second)?.itemId == "item-2")
    }

    @Test("A library-less key stores alongside a library-scoped one")
    func libraryLessKey() async {
        // #108 mounts a genre shelf on a media detail page, where there is no
        // library to scope to. The key shape has to hold that without a
        // stored-format migration.
        let cache = makeCache()
        let scoped = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        let unscoped = GenreBackdropKey(libraryId: nil, genre: "Horror")

        let store = await makeStore(cache)
        store.setSelection(selection("item-1"), for: scoped)
        store.setSelection(selection("item-2"), for: unscoped)
        await waitForCache { await stored(in: cache)?.count == 2 }

        let reloaded = await makeStore(cache)
        #expect(reloaded.selection(for: scoped)?.itemId == "item-1")
        #expect(reloaded.selection(for: unscoped)?.itemId == "item-2")
    }

    @Test("An unreadable payload reads as empty rather than throwing")
    func corruptPayload() async {
        // A blob written by a different (future or corrupted) shape: every
        // card re-rolls, which is exactly the cold-start path.
        let cache = makeCache()
        await cache.write(["not": 1], key: .genreBackdrops)

        let store = await makeStore(cache)
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        #expect(store.selection(for: key) == nil)

        // …and writing over it still works, so the app self-heals.
        store.setSelection(selection("item-1"), for: key)
        await waitForCache { await stored(in: cache)?[key.storageKey] != nil }
        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: key)?.itemId == "item-1")
    }

    // MARK: - Lifecycle

    @Test("Signing out clears the in-memory mirror, not just the cache handle")
    func deactivateClearsTheMirror() async {
        // The #192 leak, closed before #192 lands: purging the scope on disk
        // while memory still holds the picks would render the previous
        // account's artwork for the rest of the launch.
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        let store = await makeStore(makeCache())
        store.setSelection(selection("item-1"), for: key)

        store.deactivate()

        #expect(store.selection(for: key) == nil)
    }

    @Test("A stale activation cannot repopulate a deactivated store")
    func staleActivationCannotRepopulateADeactivatedStore() async {
        let cache = makeCache()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        // Seed the cache so a completing activation would have picks to leak
        await cache.write([key.storageKey: selection("item-1")], key: .genreBackdrops)

        let store = GenreBackdropStore()
        let activation = Task { await store.activate(cache: cache) }
        // Let the activation reach its suspension on the cache actor…
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        // …then sign out before it resumes. The stale completion must be
        // dropped, not merged back in across the privacy boundary.
        store.deactivate()
        await activation.value

        #expect(store.selection(for: key) == nil)
    }

    @Test("A cancelled activation discards what it read")
    func cancelledActivationDiscardsItsRead() async {
        // The arm `AppSession` relies on: `activationTask.cancel()` on
        // sign-out or on a replacement connection. Deterministic — cancelling
        // before the task starts means `Task.isCancelled` holds throughout.
        let cache = makeCache()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        await cache.write([key.storageKey: selection("item-1")], key: .genreBackdrops)

        let store = GenreBackdropStore()
        let activation = Task { await store.activate(cache: cache) }
        activation.cancel()
        await activation.value

        #expect(store.selection(for: key) == nil)
    }

    @Test("A profile switch within one launch shows none of the previous picks")
    func picksDoNotCrossScopes() async {
        let backing = MediaCacheStore.makeInMemory()
        let first = makeCache(store: backing, userID: "user-1")
        let second = makeCache(store: backing, userID: "user-2")
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

        let store = await makeStore(first)
        store.setSelection(selection("item-1"), for: key)
        await waitForCache { await stored(in: first)?[key.storageKey] != nil }

        store.deactivate()
        await store.activate(cache: second)

        #expect(store.selection(for: key) == nil)
        // The first profile's picks are still its own, untouched
        #expect(await stored(in: first)?[key.storageKey]?.itemId == "item-1")
    }

    @Test("A pick rolled before hydration lands survives, and reaches the cache")
    func preHydrationPickIsMergedAndPersisted() async {
        // A whole-map write issued before hydration would otherwise clobber
        // every stored entry — the reason `activate` re-persists after a
        // raced merge, where `UserStateStore`'s per-item writes need not.
        let cache = makeCache()
        let stale = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        let fresh = GenreBackdropKey(libraryId: "movies", genre: "Comedy")
        await cache.write([stale.storageKey: selection("item-1")], key: .genreBackdrops)

        let store = GenreBackdropStore()
        // Rolled while the card was cold, before `AppSession`'s activation landed
        store.setSelection(selection("item-2"), for: fresh)
        await store.activate(cache: cache)

        #expect(store.selection(for: stale)?.itemId == "item-1")
        #expect(store.selection(for: fresh)?.itemId == "item-2")

        await waitForCache { await stored(in: cache)?.count == 2 }
        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: stale)?.itemId == "item-1")
        #expect(reborn.selection(for: fresh)?.itemId == "item-2")
    }

    @Test("An unactivated store forgets, rather than trapping")
    func unactivatedStoreIsInert() {
        // Previews and tests build a bare `AppSession`, whose store is never
        // activated. Reads miss and writes no-op.
        let store = GenreBackdropStore()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

        store.setSelection(selection("item-1"), for: key)

        #expect(store.selection(for: key)?.itemId == "item-1")
        store.deactivate()
        #expect(store.selection(for: key) == nil)
    }
}

// MARK: - Session ownership

@Suite("AppSession genre backdrops")
@MainActor
struct AppSessionGenreBackdropTests {
    private let scope = CacheScope(serverURL: URL(string: "https://demo.example.org")!, userID: "user-1")
    private let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

    private var selection: GenreBackdropSelection {
        GenreBackdropSelection(
            itemId: "item-1",
            imageTypeRawValue: ImageType.backdrop.rawValue,
            blurHash: "hash",
            poolCount: 40,
        )
    }

    @Test("Connecting hydrates the picks and signing out drops them")
    func activatesOnConnectAndClearsOnDisconnect() async {
        let cache = ScopedCache(store: .makeInMemory(), scope: scope)
        await cache.write([key.storageKey: selection], key: .genreBackdrops)

        let session = AppSession()
        session.setClient(MockJellyfinClient(), scopedCache: cache)

        for _ in 0 ..< 200 where session.genreBackdrops.selection(for: key) == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.genreBackdrops.selection(for: key)?.itemId == "item-1")

        session.clearClient()

        // The mirror goes with the session, so the next profile in this launch
        // cannot inherit the picks
        #expect(session.genreBackdrops.selection(for: key) == nil)
    }
}

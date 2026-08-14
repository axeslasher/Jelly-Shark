@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("GenreBackdropStore")
@MainActor
struct GenreBackdropStoreTests {
    private static let serverURL = URL(string: "https://demo.example.org")!
    private static let legacyKey = "genreBackdropSelections"

    /// A scratch in-memory cache per test, so nothing leaks between them.
    /// One `MediaCacheStore` can hold several scopes, which is what makes the
    /// profile-switch cases below testable.
    private func makeCache(
        store: MediaCacheStore = .makeInMemory(),
        userID: String = "user-1",
    ) -> ScopedCache {
        ScopedCache(store: store, scope: CacheScope(serverURL: Self.serverURL, userID: userID))
    }

    /// A scratch defaults suite, so the legacy-key cleanup in `init` never
    /// touches the standard domain from a test
    private func scratchDefaults() -> UserDefaults {
        let suiteName = "GenreBackdropStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeUnboundStore() -> GenreBackdropStore {
        GenreBackdropStore(legacyDefaults: scratchDefaults())
    }

    private func makeStore(_ cache: ScopedCache) async -> GenreBackdropStore {
        let store = makeUnboundStore()
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

    private func key(_ genre: String, library: String? = "movies") -> GenreBackdropKey {
        GenreBackdropKey(libraryId: library, genre: genre)
    }

    /// The persisted map, or nil on a miss
    private func stored(in cache: ScopedCache) async -> [String: GenreBackdropSelection]? {
        await cache.read([String: GenreBackdropSelection].self, key: .genreBackdrops)
    }

    /// Poll until the fire-and-forget write lands, then assert it did — a
    /// write that never arrives should read as exactly that, rather than as a
    /// confusing mismatch further down
    private func waitForCache(
        _ condition: () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), "the cache write never landed", sourceLocation: sourceLocation)
    }

    // MARK: - Reading and writing

    @Test("Nothing is remembered before anything is chosen")
    func emptyByDefault() async {
        let store = await makeStore(makeCache())
        #expect(store.selection(for: key("Horror")) == nil)
    }

    @Test("A choice survives a relaunch")
    func persistsAcrossInstances() async {
        // The whole point of the store: `@State` dies with the view, so only a
        // trip through the cache keeps a genre's face stable across launches.
        let cache = makeCache()

        await makeStore(cache).setSelection(selection("item-1"), for: key("Horror"))
        await waitForCache { await stored(in: cache)?[key("Horror").storageKey] != nil }

        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: key("Horror")) == selection("item-1"))
    }

    @Test("Clearing a choice removes it, including from the cache")
    func clearing() async {
        let cache = makeCache()

        let store = await makeStore(cache)
        store.setSelection(selection("item-1"), for: key("Horror"))
        await waitForCache { await stored(in: cache)?[key("Horror").storageKey] != nil }
        store.setSelection(nil, for: key("Horror"))
        await waitForCache { await stored(in: cache)?[key("Horror").storageKey] == nil }

        #expect(store.selection(for: key("Horror")) == nil)
        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: key("Horror")) == nil)
    }

    @Test("The same genre in two libraries keeps two faces")
    func scopedPerLibrary() async {
        let store = await makeStore(makeCache())
        let movies = key("Horror")
        let fourK = key("Horror", library: "4k-movies")

        store.setSelection(selection("item-1"), for: movies)
        store.setSelection(selection("item-2"), for: fourK)

        #expect(store.selection(for: movies)?.itemId == "item-1")
        #expect(store.selection(for: fourK)?.itemId == "item-2")
    }

    @Test("A genre name containing a separator can't collide across libraries")
    func separatorInGenreName() async {
        // "Action/Adventure" is a real Jellyfin genre, so the key can't be
        // joined on any character a genre name might contain. Round-tripped
        // through the cache, since the U+001F key also has to survive JSON
        // dictionary encoding and SwiftData.
        let cache = makeCache()
        let first = key("b/c", library: "a")
        let second = key("c", library: "a/b")

        let store = await makeStore(cache)
        store.setSelection(selection("item-1"), for: first)
        store.setSelection(selection("item-2"), for: second)
        await waitForCache { await stored(in: cache)?.count == 2 }

        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: first)?.itemId == "item-1")
        #expect(reborn.selection(for: second)?.itemId == "item-2")
    }

    @Test("A library-less key stores alongside a library-scoped one")
    func libraryLessKey() async {
        // #108 mounts a genre shelf on a media detail page, where there is no
        // library to scope to. The key shape has to hold that without a
        // stored-format migration.
        let cache = makeCache()
        let scoped = key("Horror")
        let unscoped = key("Horror", library: nil)

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
        #expect(store.selection(for: key("Horror")) == nil)

        // …and writing over it still works, so the app self-heals.
        store.setSelection(selection("item-1"), for: key("Horror"))
        await waitForCache { await stored(in: cache)?[key("Horror").storageKey] != nil }
        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: key("Horror"))?.itemId == "item-1")
    }

    @Test("Constructing the store clears the pre-cache UserDefaults blob")
    func legacyKeyIsRemoved() {
        let defaults = scratchDefaults()
        defaults.set(Data("stale picks".utf8), forKey: Self.legacyKey)

        _ = GenreBackdropStore(legacyDefaults: defaults)

        #expect(defaults.data(forKey: Self.legacyKey) == nil)
    }

    // MARK: - Lifecycle

    @Test("Signing out clears the in-memory mirror, not just the cache handle")
    func deactivateClearsTheMirror() async {
        // The #192 leak, closed before #192 lands: purging the scope on disk
        // while memory still holds the picks would render the previous
        // account's artwork for the rest of the launch.
        let store = await makeStore(makeCache())
        store.setSelection(selection("item-1"), for: key("Horror"))

        store.deactivate()

        #expect(store.selection(for: key("Horror")) == nil)
    }

    @Test("A stale activation cannot repopulate a deactivated store")
    func staleActivationCannotRepopulateADeactivatedStore() async {
        let cache = makeCache()
        // Seed the cache so a completing activation would have picks to leak
        await cache.write([key("Horror").storageKey: selection("item-1")], key: .genreBackdrops)

        let store = makeUnboundStore()
        let activation = Task { await store.activate(cache: cache) }
        // Let the activation reach its suspension on the cache actor…
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        // …then sign out before it resumes. The stale completion must be
        // dropped, not merged back in across the privacy boundary.
        store.deactivate()
        await activation.value

        #expect(store.selection(for: key("Horror")) == nil)
    }

    @Test("A cancelled activation discards what it read")
    func cancelledActivationDiscardsItsRead() async {
        // The arm `AppSession` relies on: `activationTask.cancel()` on
        // sign-out or on a replacement connection. Deterministic — cancelling
        // before the task starts means `Task.isCancelled` holds throughout.
        let cache = makeCache()
        await cache.write([key("Horror").storageKey: selection("item-1")], key: .genreBackdrops)

        let store = makeUnboundStore()
        let activation = Task { await store.activate(cache: cache) }
        activation.cancel()
        await activation.value

        #expect(store.selection(for: key("Horror")) == nil)
    }

    @Test("A cancelled activation doesn't bind the store to the purged scope")
    func cancelledActivationLeavesTheStoreUnbound() async {
        // `AppSession` runs both stores' activations in one task, and
        // cancellation is cooperative — so this one can start after a
        // sign-out. Binding anyway would let a later pick write into the
        // scope that was just purged.
        let cache = makeCache()
        let store = makeUnboundStore()

        let activation = Task { await store.activate(cache: cache) }
        activation.cancel()
        await activation.value

        store.setSelection(selection("item-1"), for: key("Horror"))

        #expect(store.selection(for: key("Horror")) == nil)
        #expect(await stored(in: cache) == nil)
    }

    @Test("A profile switch within one launch shows none of the previous picks")
    func picksDoNotCrossScopes() async {
        let backing = MediaCacheStore.makeInMemory()
        let first = makeCache(store: backing, userID: "user-1")
        let second = makeCache(store: backing, userID: "user-2")

        let store = await makeStore(first)
        store.setSelection(selection("item-1"), for: key("Horror"))
        await waitForCache { await stored(in: first)?[key("Horror").storageKey] != nil }

        store.deactivate()
        await store.activate(cache: second)

        #expect(store.selection(for: key("Horror")) == nil)
        // The first profile's picks are still its own, untouched
        #expect(await stored(in: first)?[key("Horror").storageKey]?.itemId == "item-1")
    }

    @Test("Re-activating on another profile without signing out carries nothing over")
    func reactivatingADifferentScopeDropsTheMirror() async {
        // The #192 profile switch, minus the `deactivate()`. Without the
        // scope check in `activate`, the memory-wins merge would hand the
        // second profile the first's picks *and* the re-persist would write
        // them into the second profile's row — a durable cross-profile leak.
        let backing = MediaCacheStore.makeInMemory()
        let first = makeCache(store: backing, userID: "user-1")
        let second = makeCache(store: backing, userID: "user-2")

        let store = await makeStore(first)
        store.setSelection(selection("item-1"), for: key("Horror"))
        await waitForCache { await stored(in: first)?[key("Horror").storageKey] != nil }

        await store.activate(cache: second)

        #expect(store.selection(for: key("Horror")) == nil)
        // …and nothing was written into the second profile's row on the way
        #expect(await stored(in: second) == nil)
    }

    @Test("A pick rolled during the hydration window survives, and repairs the blob")
    func hydrationWindowPickIsMergedAndPersisted() async {
        // The reason `activate` re-persists after a raced merge, where
        // `UserStateStore`'s per-item writes need not: this store writes the
        // whole map, so a pick landing mid-hydration has already written a
        // blob that omits every stored entry.
        let cache = makeCache()
        let stale = key("Horror")
        let fresh = key("Comedy")
        await cache.write([stale.storageKey: selection("item-1")], key: .genreBackdrops)

        let store = makeUnboundStore()
        let activation = Task { await store.activate(cache: cache) }
        // Parked on the cache actor, so the handle is bound but the merge
        // hasn't happened — exactly when a cold card rolls
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        store.setSelection(selection("item-2"), for: fresh)
        await activation.value

        #expect(store.selection(for: stale)?.itemId == "item-1")
        #expect(store.selection(for: fresh)?.itemId == "item-2")

        await waitForCache { await stored(in: cache)?.count == 2 }
        let reborn = await makeStore(cache)
        #expect(reborn.selection(for: stale)?.itemId == "item-1")
        #expect(reborn.selection(for: fresh)?.itemId == "item-2")
    }

    @Test("An unbound store drops picks rather than holding them for the next profile")
    func unboundStoreDropsPicks() async {
        // A card's roll is a detached `Task`, so it can resume after sign-out
        // has deactivated the store. Keeping the pick with no scope to
        // attribute it to would let the next profile's `activate` adopt it —
        // and persist it into that profile's row.
        let cache = makeCache()
        let store = await makeStore(cache)
        store.deactivate()

        store.setSelection(selection("item-1"), for: key("Horror"))

        #expect(store.selection(for: key("Horror")) == nil)

        // The next profile signs in and inherits nothing
        await store.activate(cache: makeCache(userID: "user-2"))
        #expect(store.selection(for: key("Horror")) == nil)
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

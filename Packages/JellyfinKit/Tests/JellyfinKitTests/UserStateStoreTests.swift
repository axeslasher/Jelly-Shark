import Foundation
@testable import JellyfinKit
import Testing

@Suite("UserStateStore")
@MainActor
struct UserStateStoreTests {
    private let cache = ScopedCache(
        store: .makeInMemory(),
        scope: CacheScope(serverURL: URL(string: "https://demo.example.org")!, userID: "user-1"),
    )

    private func item(
        _ id: String,
        played: Bool = false,
        favorite: Bool = false,
        position: Int64? = nil,
        unplayedCount: Int? = nil,
    ) -> MediaItem {
        MediaItem(
            id: id,
            name: id,
            type: .movie,
            userData: UserData(
                playbackPositionTicks: position,
                isFavorite: favorite,
                played: played,
                unplayedItemCount: unplayedCount,
            ),
        )
    }

    /// Poll until the fire-and-forget persistence task lands (bounded)
    private func waitForTable(_ condition: () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Resolve overlay

    @Test func resolveWithoutStateReturnsTheItemUntouched() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        let bare = item("m-1", played: true, position: 500)
        #expect(store.resolve(bare) == bare)
    }

    @Test func ingestedStateOverlaysAtReadTime() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", played: true, favorite: true, position: 900)])

        // A stale copy of the same item resolves to the ingested truth,
        // wherever it renders
        let stale = item("m-1")
        let resolved = store.resolve(stale)
        #expect(resolved.userData?.played == true)
        #expect(resolved.userData?.isFavorite == true)
        #expect(resolved.userData?.playbackPositionTicks == 900)
    }

    @Test func containerUnplayedCountStaysTheItemsOwn() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("series-1", played: false)])

        let series = item("series-1", unplayedCount: 7)
        #expect(store.resolve(series).userData?.unplayedItemCount == 7)
    }

    @Test func playedContainerResolvesZeroUnwatched() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        let series = item("series-1", unplayedCount: 7)

        // Marking a container watched has nothing unwatched left — a played
        // badge next to a stale "7" would contradict itself
        let token = store.beginPlayedToggle(itemID: "series-1", target: true)
        #expect(store.resolve(series).userData?.unplayedItemCount == 0)

        store.confirm(token)
        #expect(store.resolve(series).userData?.unplayedItemCount == 0)

        // Marking unwatched falls back to the item's own count
        let back = store.beginPlayedToggle(itemID: "series-1", target: false)
        store.confirm(back)
        #expect(store.resolve(series).userData?.unplayedItemCount == 7)
    }

    @Test func staleActivationCannotRepopulateADeactivatedStore() async {
        // Seed the table so a completing activation would have rows to leak
        await cache.store.ingestServerUserData(
            scope: cache.scope,
            items: [item("m-1", played: true, favorite: true)],
        )

        let store = UserStateStore()
        let activation = Task { await store.activate(cache: cache) }
        // Let the activation reach its suspension on the cache actor…
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        // …then sign out before it resumes. The stale completion must be
        // dropped, not merged back in across the privacy boundary.
        store.deactivate()
        await activation.value

        #expect(store.resolve(item("m-1")) == item("m-1"))
        #expect(store.isFavorite(itemID: "m-1", fallback: false) == false)
    }

    @Test func ingestSkipsItemsWithoutUserDataOrRealId() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        let bare = MediaItem(id: "bare", name: "bare", type: .movie)
        store.ingest(serverItems: [bare, item("", played: true)])
        #expect(store.resolve(item("bare")) == item("bare"))
    }

    // MARK: - Toggles

    @Test func pendingToggleDisplaysImmediatelyAndConfirmCommits() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", position: 900)])

        let token = store.beginPlayedToggle(itemID: "m-1", target: true)
        // Displayed at once, resume progress cleared like settingPlayed
        var resolved = store.resolve(item("m-1"))
        #expect(resolved.userData?.played == true)
        #expect(resolved.userData?.playbackPositionTicks == nil)

        store.confirm(token)
        resolved = store.resolve(item("m-1"))
        #expect(resolved.userData?.played == true)
        #expect(resolved.userData?.playbackPositionTicks == nil)
    }

    @Test func revertWithdrawsTheDisplayedToggle() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", favorite: true)])

        let token = store.beginFavoriteToggle(itemID: "m-1", target: false)
        #expect(store.resolve(item("m-1")).userData?.isFavorite == false)

        store.revert(token)
        // Committed state was never touched: the pre-toggle truth returns
        #expect(store.resolve(item("m-1")).userData?.isFavorite == true)
    }

    @Test func ingestCannotClobberAPendingToggle() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", played: false)])

        let token = store.beginPlayedToggle(itemID: "m-1", target: true)
        // An unrelated refresh lands mid-flight, reporting the pre-toggle
        // state — the #193 symptom-2 interleave
        store.ingest(serverItems: [item("m-1", played: false, favorite: true)])

        // The toggle's field held; the other field took the server's word
        var resolved = store.resolve(item("m-1"))
        #expect(resolved.userData?.played == true)
        #expect(resolved.userData?.isFavorite == true)

        store.confirm(token)
        resolved = store.resolve(item("m-1"))
        #expect(resolved.userData?.played == true)
    }

    @Test func aNewerToggleSupersedesAnOlderInFlightOne() async {
        let store = UserStateStore()
        await store.activate(cache: cache)

        let first = store.beginPlayedToggle(itemID: "m-1", target: true)
        let second = store.beginPlayedToggle(itemID: "m-1", target: false)

        // The superseded token's outcome is ignored either way
        store.confirm(first)
        #expect(store.resolve(item("m-1", played: true)).userData?.played == false)

        store.confirm(second)
        #expect(store.resolve(item("m-1", played: true)).userData?.played == false)
    }

    // MARK: - Progress

    @Test func recordPositionNeverFlipsPlayed() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", played: false)])

        // A stop at 92% is still the server's call to make (#193)
        store.recordPosition(itemID: "m-1", ticks: 55_200_000_000)

        let resolved = store.resolve(item("m-1"))
        #expect(resolved.userData?.played == false)
        #expect(resolved.userData?.playbackPositionTicks == 55_200_000_000)
    }

    // MARK: - Person favorites

    @Test func personFavoriteReadsAndSeedsThroughTheStore() async {
        let store = UserStateStore()
        await store.activate(cache: cache)

        #expect(store.isFavorite(itemID: "person-1", fallback: true) == true)

        store.ingestServerFavorite(itemID: "person-1", isFavorite: false)
        #expect(store.isFavorite(itemID: "person-1", fallback: true) == false)

        let token = store.beginFavoriteToggle(itemID: "person-1", target: true)
        #expect(store.isFavorite(itemID: "person-1", fallback: false) == true)
        // The seed is pending-guarded exactly like ingest
        store.ingestServerFavorite(itemID: "person-1", isFavorite: false)
        store.confirm(token)
        #expect(store.isFavorite(itemID: "person-1", fallback: false) == true)
    }

    // MARK: - Lifecycle

    @Test func activateSeedsFromTheTableAndConfirmPersistsBack() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", favorite: true)])
        let token = store.beginPlayedToggle(itemID: "m-1", target: true)
        store.confirm(token)

        // The fire-and-forget writes land in the table…
        await waitForTable {
            await cache.store.userStates(scope: cache.scope, itemIDs: ["m-1"])["m-1"]?.played == true
        }

        // …and a fresh store on the same cache cold-starts with them
        let reborn = UserStateStore()
        await reborn.activate(cache: cache)
        let resolved = reborn.resolve(item("m-1"))
        #expect(resolved.userData?.played == true)
        #expect(resolved.userData?.isFavorite == true)
    }

    @Test func deactivateDropsEverything() async {
        let store = UserStateStore()
        await store.activate(cache: cache)
        store.ingest(serverItems: [item("m-1", played: true)])
        _ = store.beginFavoriteToggle(itemID: "m-1", target: true)

        store.deactivate()

        // The next account's identical item id resolves to its own data only
        #expect(store.resolve(item("m-1")) == item("m-1"))
        #expect(store.isFavorite(itemID: "m-1", fallback: false) == false)
    }
}

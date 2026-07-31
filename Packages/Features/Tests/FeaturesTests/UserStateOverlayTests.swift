@testable import Features
import Foundation
import JellyfinKit
import Testing

/// The #193 acceptance criteria, end to end at the view-model layer: one
/// shared `UserStateStore` is the display authority for watched/favorite/
/// progress, so state changed anywhere renders correctly everywhere on the
/// first frame — no refetch in between.
@Suite("User-state overlay across screens")
@MainActor
struct UserStateOverlayTests {
    private func movie(_ id: String, userData: UserData? = nil) -> MediaItem {
        MediaItem(id: id, name: id, type: .movie, imageTags: ImageTags(backdrop: "tag"), userData: userData)
    }

    @Test("Player-made changes show on Home's first frame, hero and shelf alike")
    func playerChangesShowWithoutARefetch() async {
        let shared = UserStateStore()
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([
            movie("m-1", userData: UserData(playbackPositionTicks: 100, isFavorite: false)),
        ])

        let home = HomeViewModel()
        home.attach(client: client, libraries: [], cache: nil, userState: shared)
        await home.load()
        #expect(home.resumeItems.first?.userData?.isFavorite == false)

        // The "player": favorite toggled mid-session and the playhead moved,
        // through the same shared store the player writes to
        let token = shared.beginFavoriteToggle(itemID: "m-1", target: true)
        shared.confirm(token)
        shared.recordPosition(itemID: "m-1", ticks: 5000)

        // Home has NOT refetched — the overlay alone carries the truth
        #expect(home.resumeItems.first?.userData?.isFavorite == true)
        #expect(home.resumeItems.first?.userData?.playbackPositionTicks == 5000)
    }

    @Test("A detail-page toggle renders on a Home shelf sharing the store")
    func detailToggleReachesHomeShelf() async {
        let shared = UserStateStore()
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("m-1")])
        client.mediaItemsById["m-1"] = movie("m-1")

        let home = HomeViewModel()
        home.attach(client: client, libraries: [], cache: nil, userState: shared)
        await home.load()

        let detail = MediaDetailViewModel()
        detail.attach(client: client, item: movie("m-1"), userState: shared)
        await detail.load()

        await detail.toggleHeroFavorite()

        #expect(detail.heroIsFavorite == true)
        #expect(home.resumeItems.first?.userData?.isFavorite == true)
    }

    @Test("A hero toggle in flight is not clobbered by an unrelated refresh")
    func inFlightToggleSurvivesARefresh() async {
        let shared = UserStateStore()
        let client = MockJellyfinClient()
        // The server keeps reporting the pre-toggle state
        client.resumeItemsResult = .success([movie("m-1", userData: UserData(played: false))])

        let home = HomeViewModel()
        home.attach(client: client, libraries: [], cache: nil, userState: shared)
        await home.load()

        let gate = AsyncGate()
        client.userDataDelay = { await gate.wait() }
        let toggle = Task { await home.setPlayed(true, for: movie("m-1")) }

        // An unrelated refresh lands while the mark call is held in flight —
        // the #193 symptom-2 interleave. The pending toggle must keep
        // displaying the viewer's choice. (The pending display is the
        // MainActor signal that the toggle has begun.)
        await waitUntilMain { home.resumeItems.first?.userData?.played == true }
        await home.refreshUserState()
        #expect(home.resumeItems.first?.userData?.played == true)

        await gate.open()
        await toggle.value
        #expect(home.resumeItems.first?.userData?.played == true)
    }

    @Test("Marking watched clears the resolved progress — Replay, never a stale Resume")
    func toggleWatchedClearsResolvedProgress() async {
        let shared = UserStateStore()
        let client = MockJellyfinClient()
        client.mediaItemsById["m-1"] = MediaItem(
            id: "m-1",
            name: "m-1",
            type: .movie,
            runTimeTicks: 60_000_000_000,
            userData: UserData(playbackPositionTicks: 30_000_000_000),
        )

        let detail = MediaDetailViewModel()
        detail.attach(client: client, item: movie("m-1"), userState: shared)
        await detail.load()
        #expect(detail.detailedItem?.hasProgress == true)

        await detail.toggleHeroPlayed()

        // Both the flag and the progress resolve together, so the Play
        // button can never read a stale "Resume" next to a watched badge
        #expect(detail.heroIsPlayed == true)
        #expect(detail.detailedItem?.hasProgress == false)
    }
}

/// Poll until the condition holds (bounded); local to this file to avoid
/// cross-file helper collisions.
@MainActor
private func waitUntilMain(_ condition: () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("MediaDetailViewModel")
@MainActor
struct MediaDetailViewModelTests {
    private func movie(_ id: String, people: [CastMember]? = nil) -> MediaItem {
        MediaItem(id: id, name: id, type: .movie, people: people)
    }

    private func series(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .series)
    }

    private func episode(_ id: String, seriesId: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .episode, seriesId: seriesId)
    }

    private func boxSet(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .boxSet)
    }

    /// Attach + load in one step, mirroring the view's `.task`.
    private func load(
        _ viewModel: MediaDetailViewModel,
        client: MockJellyfinClient?,
        item: MediaItem,
    ) async {
        viewModel.attach(client: client, item: item)
        await viewModel.load()
    }

    // MARK: - Core load

    @Test("A movie loads its detail and derives the credits")
    func movieLoadsAndDerivesCredits() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["m1"] = movie("m1", people: [
            CastMember(id: "d1", name: "Director One", kind: "Director"),
            // Mislabeled crew: `kind` says Actor, the function lives in `role`.
            CastMember(id: "d2", name: "Director Two", role: "Director", kind: "Actor"),
            CastMember(id: "a1", name: "Actor One", role: "Neo", kind: "Actor"),
            CastMember(id: "a2", name: "Actor Two", role: "Trinity", kind: "Actor"),
            CastMember(id: "a3", name: "Actor Three", role: "Morpheus", kind: "Actor"),
            CastMember(id: "a4", name: "Actor Four", role: "Smith", kind: "Actor"),
        ])

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))

        #expect(viewModel.status == .loaded)
        #expect(viewModel.detailedItem?.id == "m1")
        #expect(viewModel.directors.map(\.id) == ["d1", "d2"])
        // First 3 billed actors, excluding the mislabeled director.
        #expect(viewModel.topCast.map(\.id) == ["a1", "a2", "a3"])
    }

    @Test("A failed detail fetch reports .failed and Retry recovers")
    func coreFailureRetries() async {
        let client = MockJellyfinClient()
        client.mediaItemFailureIds = ["m1"]

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))

        #expect(viewModel.status.isFailed)
        // Never the stub: the view keeps rendering its own copy instead.
        #expect(viewModel.detailedItem == nil)

        client.mediaItemFailureIds = []
        client.mediaItemsById["m1"] = movie("m1")
        await viewModel.retry()

        #expect(viewModel.status == .loaded)
        #expect(viewModel.detailedItem?.id == "m1")
    }

    @Test("A failed load re-arms the next appearance's load")
    func failureRearmsReappearance() async {
        let client = MockJellyfinClient()
        client.mediaItemFailureIds = ["m1"]

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))
        #expect(viewModel.status.isFailed)

        // The reappearance re-fires attach + load with unchanged inputs.
        client.mediaItemFailureIds = []
        await load(viewModel, client: client, item: movie("m1"))

        #expect(viewModel.status == .loaded)
    }

    @Test("Loads once per item; a reappearance is a no-op")
    func loadOncePerItem() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["m1"] = movie("m1")

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))
        #expect(client.mediaItemRequests == ["m1"])

        await load(viewModel, client: client, item: movie("m1"))
        #expect(client.mediaItemRequests == ["m1"])
    }

    @Test("A nil client parks at .loading — the stub keeps the page rendered")
    func nilClientStaysLoading() async {
        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: nil, item: movie("m1"))

        #expect(viewModel.status == .loading)
        #expect(viewModel.detailedItem == nil)
    }

    // MARK: - Series

    @Test("A series loads seasons and episodes with the detail")
    func seriesLoadsEpisodes() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.seasonsResult = .success([MediaItem(id: "season-1", name: "Season 1", type: .season)])
        client.episodesResult = .success([episode("e1", seriesId: "s1")])
        client.nextUpEpisodesBySeries["s1"] = episode("e2", seriesId: "s1")

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))

        #expect(viewModel.status == .loaded)
        #expect(viewModel.seasons.map(\.id) == ["season-1"])
        #expect(viewModel.episodes.map(\.id) == ["e1"])
        #expect(viewModel.nextUpEpisode?.id == "e2")
    }

    @Test("A failed episodes fetch fails the page even when the detail landed")
    func seriesEpisodesFailureFails() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .failure(APIError.networkError("offline"))

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))

        #expect(viewModel.status.isFailed)
        // The detail that did land still upgrades the hero.
        #expect(viewModel.detailedItem?.id == "s1")
    }

    @Test("A failed next-up fetch is enrichment — the page still loads")
    func nextUpFailureIsEnrichment() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .success([episode("e1", seriesId: "s1")])
        client.nextUpEpisodeError = APIError.networkError("offline")

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))

        #expect(viewModel.status == .loaded)
        #expect(viewModel.nextUpEpisode == nil)
        // The Play button's `episodes.first` fallback stays available.
        #expect(viewModel.episodes.map(\.id) == ["e1"])
    }

    // MARK: - Collections

    @Test("A failed collection fetch fails a box-set page")
    func boxSetCollectionFailureFails() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["b1"] = boxSet("b1")
        client.collectionItemsResult = .failure(APIError.networkError("offline"))

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: boxSet("b1"))

        #expect(viewModel.status.isFailed)
    }

    // MARK: - Enrichment

    @Test("A failed similar-items fetch never fails the page")
    func similarItemsFailureIsEnrichment() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["m1"] = movie("m1")
        client.similarItemsResult = .failure(APIError.networkError("offline"))

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))

        #expect(viewModel.status == .loaded)
        #expect(viewModel.similarItems.isEmpty)
    }

    // MARK: - Item changes

    @Test("Attaching a new item resets the previous item's sections")
    func attachNewItemResets() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .success([episode("e1", seriesId: "s1")])

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))
        #expect(viewModel.episodes.map(\.id) == ["e1"])

        client.mediaItemsById["m2"] = movie("m2")
        await load(viewModel, client: client, item: movie("m2"))

        #expect(viewModel.detailedItem?.id == "m2")
        #expect(viewModel.episodes.isEmpty)
        #expect(viewModel.seasons.isEmpty)
    }

    // MARK: - Post-playback refresh

    @Test("A failed post-playback refresh keeps the last-good data")
    func refreshFailureKeepsLastGood() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .success([episode("e1", seriesId: "s1")])

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))
        #expect(viewModel.status == .loaded)

        // The connection dropped while the player was up.
        client.mediaItemFailureIds = ["s1"]
        client.episodesResult = .failure(APIError.networkError("offline"))
        await viewModel.refreshAfterPlayback()

        #expect(viewModel.status == .loaded)
        #expect(viewModel.detailedItem?.id == "s1")
        #expect(viewModel.episodes.map(\.id) == ["e1"])
    }

    @Test("A post-playback refresh updates watch state in place")
    func refreshUpdatesInPlace() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .success([episode("e1", seriesId: "s1")])

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))

        client.episodesResult = .success([episode("e1", seriesId: "s1"), episode("e2", seriesId: "s1")])
        client.nextUpEpisodesBySeries["s1"] = episode("e2", seriesId: "s1")
        await viewModel.refreshAfterPlayback()

        #expect(viewModel.episodes.map(\.id) == ["e1", "e2"])
        #expect(viewModel.nextUpEpisode?.id == "e2")
    }

    // MARK: - User-data actions (episode card menus)

    @Test("setPlayed persists and refreshes next-up like a finished playback")
    func setPlayedRefreshesNextUp() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .success([episode("e1", seriesId: "s1"), episode("e2", seriesId: "s1")])
        client.nextUpEpisodesBySeries["s1"] = episode("e1", seriesId: "s1")

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))
        #expect(viewModel.nextUpEpisode?.id == "e1")

        // Watching e1 "by decree" advances the server's next-up to e2.
        client.nextUpEpisodesBySeries["s1"] = episode("e2", seriesId: "s1")
        await viewModel.setPlayed(true, for: viewModel.episodes[0])

        #expect(client.userDataCalls.map(\.action) == ["played"])
        #expect(client.userDataCalls.map(\.itemId) == ["e1"])
        #expect(viewModel.nextUpEpisode?.id == "e2")
    }

    @Test("setFavorite flips the episode in place and reverts on failure")
    func setFavoriteFlipsEpisode() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["s1"] = series("s1")
        client.episodesResult = .success([episode("e1", seriesId: "s1")])

        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: series("s1"))

        await viewModel.setFavorite(true, for: viewModel.episodes[0])
        #expect(viewModel.episodes[0].userData?.isFavorite == true)

        client.userDataError = APIError.networkError("offline")
        await viewModel.setFavorite(false, for: viewModel.episodes[0])
        #expect(viewModel.episodes[0].userData?.isFavorite == true)
    }

    // MARK: - Hero toggles

    @Test("toggleHeroPlayed marks an unwatched item, then unmarks it")
    func heroPlayedToggles() async {
        let client = MockJellyfinClient()
        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))
        #expect(viewModel.heroIsPlayed == false)

        await viewModel.toggleHeroPlayed()
        #expect(viewModel.heroIsPlayed == true)

        await viewModel.toggleHeroPlayed()
        #expect(viewModel.heroIsPlayed == false)
        #expect(client.userDataCalls.map(\.action) == ["played", "unplayed"])
        #expect(client.userDataCalls.map(\.itemId) == ["m1", "m1"])
    }

    @Test("toggleHeroFavorite favorites, then unfavorites")
    func heroFavoriteToggles() async {
        let client = MockJellyfinClient()
        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))

        await viewModel.toggleHeroFavorite()
        #expect(viewModel.heroIsFavorite == true)

        await viewModel.toggleHeroFavorite()
        #expect(viewModel.heroIsFavorite == false)
        #expect(client.userDataCalls.map(\.action) == ["favorite", "unfavorite"])
    }

    @Test("A watched item's hero toggle starts from the fetched state")
    func heroPlayedStartsFromFetchedState() async {
        let client = MockJellyfinClient()
        client.mediaItemsById["m1"] = MediaItem(
            id: "m1", name: "m1", type: .movie,
            userData: UserData(played: true),
        )
        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))
        #expect(viewModel.heroIsPlayed == true)

        await viewModel.toggleHeroPlayed()
        #expect(client.userDataCalls.map(\.action) == ["unplayed"])
        #expect(viewModel.heroIsPlayed == false)
    }

    @Test("Hero toggles revert the optimistic flip when the server call fails")
    func heroTogglesRevertOnFailure() async {
        let client = MockJellyfinClient()
        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))

        client.userDataError = APIError.networkError("offline")
        await viewModel.toggleHeroPlayed()
        await viewModel.toggleHeroFavorite()

        #expect(viewModel.heroIsPlayed == false)
        #expect(viewModel.heroIsFavorite == false)
    }

    @Test("Attaching a new item resets the hero's pending overrides")
    func heroOverridesResetOnNewItem() async {
        let client = MockJellyfinClient()
        let viewModel = MediaDetailViewModel()
        await load(viewModel, client: client, item: movie("m1"))
        await viewModel.toggleHeroPlayed()
        await viewModel.toggleHeroFavorite()
        #expect(viewModel.heroIsPlayed == true)

        await load(viewModel, client: client, item: movie("m2"))
        #expect(viewModel.heroPlayedOverride == nil)
        #expect(viewModel.heroIsPlayed == false)
        #expect(viewModel.heroIsFavorite == false)
    }
}

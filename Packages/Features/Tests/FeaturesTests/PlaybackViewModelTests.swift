import Testing
import Foundation
import JellyfinKit
@testable import Features

// MARK: - Mock Client

/// Mock Jellyfin client that records playback calls for assertions
final class MockJellyfinClient: JellyfinClientProtocol, @unchecked Sendable {
    let serverURL = URL(string: "https://example.com")!
    var currentUser: User?
    var isAuthenticated: Bool { currentUser != nil }
    var accessToken: String?

    // Recorded calls
    var playbackInfoRequests: [(itemId: String, startTimeTicks: Int64?, audioStreamIndex: Int?, subtitleStreamIndex: Int?)] = []
    var startReports: [(itemId: String, positionTicks: Int64)] = []
    var progressReports: [(itemId: String, positionTicks: Int64, isPaused: Bool)] = []
    var stopReports: [(itemId: String, positionTicks: Int64)] = []
    var nextEpisodeRequests: [String] = []
    var fetchCurrentUserCallCount = 0

    // Stubbed responses
    var playbackInfoResult: Result<PlaybackSessionInfo, Error> = .success(
        PlaybackSessionInfo(
            playSessionId: "session-1",
            mediaSources: [MediaSource(id: "source-1")]
        )
    )
    var nextEpisodeResult: MediaItem?
    var fetchCurrentUserResult: Result<User, Error> = .success(User(id: "user-1", name: "demo"))
    var librariesResult: Result<[Library], Error> = .success([])
    var searchQueries: [String] = []
    var searchResult: Result<[MediaItem], Error> = .success([])

    func authenticate(username: String, password: String) async throws -> User {
        let user = User(id: "user-1", name: username)
        currentUser = user
        accessToken = "token-1"
        return user
    }

    func signOut() async {
        currentUser = nil
        accessToken = nil
    }

    func fetchCurrentUser() async throws -> User {
        fetchCurrentUserCallCount += 1
        let user = try fetchCurrentUserResult.get()
        currentUser = user
        return user
    }

    func getLibraries() async throws -> [Library] { try librariesResult.get() }

    func getLibraryItems(libraryId: String, itemTypes: [MediaType]?, limit: Int?, startIndex: Int?) async throws -> [MediaItem] { [] }

    func getMediaItem(itemId: String) async throws -> MediaItem {
        MediaItem(id: itemId, name: "Item", type: .movie)
    }

    func getSimilarItems(itemId: String, limit: Int?) async throws -> [MediaItem] { [] }

    func searchItems(query: String, limit: Int?) async throws -> [MediaItem] {
        searchQueries.append(query)
        return try searchResult.get()
    }

    func getImageURL(itemId: String, imageType: ImageType, maxWidth: Int?, maxHeight: Int?) -> URL {
        serverURL
    }

    func getResumeItems(limit: Int?) async throws -> [MediaItem] { [] }

    func getLatestItems(libraryId: String?, limit: Int?) async throws -> [MediaItem] { [] }

    func getPlaybackInfo(
        itemId: String,
        startTimeTicks: Int64?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackSessionInfo {
        playbackInfoRequests.append((itemId, startTimeTicks, audioStreamIndex, subtitleStreamIndex))
        return try playbackInfoResult.get()
    }

    func hlsStreamURL(parameters: StreamParameters, eTag: String?) throws -> URL {
        URL(string: "https://example.com/Videos/\(parameters.itemId)/main.m3u8")!
    }

    func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws {
        startReports.append((itemId, positionTicks))
    }

    func reportPlaybackProgress(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        isPaused: Bool
    ) async throws {
        progressReports.append((itemId, positionTicks, isPaused))
    }

    func reportPlaybackStopped(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64
    ) async throws {
        stopReports.append((itemId, positionTicks))
    }

    func getNextEpisode(after episode: MediaItem) async throws -> MediaItem? {
        nextEpisodeRequests.append(episode.id)
        return nextEpisodeResult
    }

    func getSeasons(seriesId: String) async throws -> [MediaItem] { [] }
    func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] { [] }
    func getNextUpEpisode(seriesId: String) async throws -> MediaItem? { nil }

    func markPlayed(itemId: String) async throws {}
    func markUnplayed(itemId: String) async throws {}
    func markFavorite(itemId: String) async throws {}
    func unmarkFavorite(itemId: String) async throws {}
}

// MARK: - Tests

@Suite("PlaybackViewModel")
@MainActor
struct PlaybackViewModelTests {
    private func makeMovie(resumeTicks: Int64? = nil) -> MediaItem {
        MediaItem(
            id: "movie-1",
            name: "Test Movie",
            type: .movie,
            runTimeTicks: 72_000_000_000,
            userData: resumeTicks.map { UserData(playbackPositionTicks: $0) }
        )
    }

    @Test("start() transitions to playing and reports start")
    func startReachesPlaying() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        #expect(viewModel.state == .idle)
        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(viewModel.player != nil)
        #expect(viewModel.mediaSource?.id == "source-1")
        #expect(client.startReports.count == 1)
        #expect(client.startReports[0].itemId == "movie-1")
        #expect(client.startReports[0].positionTicks == 0)
    }

    @Test("start() requests playback info with the resume position")
    func startWithResumePosition() async {
        let client = MockJellyfinClient()
        let resumeTicks: Int64 = 6_000_000_000 // 10 minutes
        let viewModel = PlaybackViewModel(client: client, item: makeMovie(resumeTicks: resumeTicks))

        await viewModel.start()

        #expect(client.playbackInfoRequests.count == 1)
        #expect(client.playbackInfoRequests[0].startTimeTicks == resumeTicks)
        #expect(client.startReports[0].positionTicks == resumeTicks)
    }

    @Test("start() failure surfaces as failed state")
    func startFailure() async {
        let client = MockJellyfinClient()
        client.playbackInfoResult = .failure(APIError.generic("Playback not possible"))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .failed("Playback not possible"))
        #expect(viewModel.player == nil)
        #expect(client.startReports.isEmpty)
    }

    @Test("Empty media sources surface as failed state")
    func emptyMediaSources() async {
        let client = MockJellyfinClient()
        client.playbackInfoResult = .success(PlaybackSessionInfo(playSessionId: "s", mediaSources: []))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .failed("No playable media sources for this item"))
    }

    @Test("stop() reports stopped and is idempotent")
    func stopReportsAndIsIdempotent() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.stop()
        await viewModel.stop()

        #expect(client.stopReports.count == 1)
        #expect(client.stopReports[0].itemId == "movie-1")
        #expect(viewModel.player == nil)
    }

    @Test("Progress is reported periodically")
    func progressReporting() async throws {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(
            client: client,
            item: makeMovie(),
            progressInterval: .milliseconds(50)
        )

        await viewModel.start()
        try await Task.sleep(for: .milliseconds(200))
        await viewModel.stop()

        #expect(client.progressReports.count >= 2)
        #expect(client.progressReports.allSatisfy { $0.itemId == "movie-1" })
    }

    @Test("Track selection rebuilds the stream with the selected index")
    func trackSelectionRebuildsStream() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: 3)

        #expect(client.playbackInfoRequests.count == 2)
        #expect(client.playbackInfoRequests[1].subtitleStreamIndex == 3)
        #expect(viewModel.selectedSubtitleStreamIndex == 3)
        #expect(viewModel.state == .playing)
        #expect(client.startReports.count == 2)
    }

    @Test("Selecting the already-selected track is a no-op")
    func selectingSameTrackIsNoOp() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)

        #expect(client.playbackInfoRequests.count == 1)
    }

    @Test("playNextEpisodeNow() closes the session and starts the next episode")
    func playNextEpisode() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        let next = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = next

        let viewModel = PlaybackViewModel(client: client, item: episode)
        await viewModel.start()

        // Simulate end-of-item discovery having queued the next episode,
        // then the user (or countdown) advancing
        await viewModel.handlePlaybackEnded()
        #expect(viewModel.nextEpisode == next)

        await viewModel.playNextEpisodeNow()

        #expect(viewModel.item.id == "ep-2")
        #expect(viewModel.state == .playing)
        #expect(viewModel.nextEpisode == nil)
        #expect(client.stopReports.count == 1)
        #expect(client.stopReports[0].itemId == "ep-1")
        #expect(client.startReports.count == 2)
    }

    @Test("Movies finish without consulting next episode")
    func moviesDoNotAutoplay() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.handlePlaybackEnded()

        #expect(client.nextEpisodeRequests.isEmpty)
        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }

    @Test("Last episode finishes without queueing autoplay")
    func lastEpisodeFinishes() async {
        let client = MockJellyfinClient()
        client.nextEpisodeResult = nil
        let episode = MediaItem(id: "ep-9", name: "Finale", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()

        #expect(client.nextEpisodeRequests == ["ep-9"])
        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }

    @Test("cancelAutoplay() finishes the session")
    func cancelAutoplay() async {
        let client = MockJellyfinClient()
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()
        viewModel.cancelAutoplay()

        #expect(viewModel.nextEpisode == nil)
        #expect(viewModel.state == .finished)
    }
}

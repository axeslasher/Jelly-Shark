@testable import Features
import Foundation
import JellyfinKit
import Testing

// MARK: - Mock Client

/// Mock Jellyfin client that records playback calls for assertions
final class MockJellyfinClient: JellyfinClientProtocol, @unchecked Sendable {
    /// Guards the recording arrays: the view model fans narrowing scans out
    /// concurrently, so unsynchronized appends would race
    private let lock = NSLock()

    let serverURL = URL(string: "https://example.com")!
    var currentUser: User?
    var isAuthenticated: Bool {
        currentUser != nil
    }

    var accessToken: String?

    // Recorded calls
    var playbackInfoRequests: [(itemId: String, startTimeTicks: Int64?, audioStreamIndex: Int?, subtitleStreamIndex: Int?)] = []
    var streamResolutions: [(sourceId: String, parameters: StreamParameters, playMethod: PlayMethod)] = []
    var startReports: [(itemId: String, positionTicks: Int64, playMethod: PlayMethod)] = []
    var progressReports: [(itemId: String, positionTicks: Int64, isPaused: Bool, playMethod: PlayMethod, audioStreamIndex: Int?, subtitleStreamIndex: Int?)] = []
    var stopReports: [(itemId: String, positionTicks: Int64)] = []
    var nextEpisodeRequests: [String] = []
    var fetchCurrentUserCallCount = 0

    /// Stubbed responses
    var playbackInfoResult: Result<PlaybackSessionInfo, Error> = .success(
        PlaybackSessionInfo(
            playSessionId: "session-1",
            mediaSources: [MediaSource(id: "source-1")],
        ),
    )
    var nextEpisodeResult: MediaItem?
    var fetchCurrentUserResult: Result<User, Error> = .success(User(id: "user-1", name: "demo"))
    var librariesResult: Result<[Library], Error> = .success([])
    var searchQueries: [String] = []
    var searchResult: Result<[MediaItem], Error> = .success([])
    var personResult: Result<Person, Error> = .success(Person(id: "person-id", name: "Person"))
    var itemsFeaturingPersonRequests: [(personId: String, itemTypes: [MediaType])] = []
    var libraryItemsRequests: [(libraryId: String, query: LibraryQuery, limit: Int, startIndex: Int)] = []
    /// Pages served in request order; the last page repeats once exhausted
    var libraryItemsPages: [Result<MediaItemPage, Error>] = [
        .success(MediaItemPage(items: [], startIndex: 0, totalRecordCount: 0)),
    ]
    /// Optional gate awaited before serving a library page, for in-flight tests
    var libraryItemsDelay: (() async -> Void)?
    var filterOptionsResult: Result<LibraryFilterOptions, Error> = .success(.empty)
    /// Per-library filter options (the genre builds fan out per library);
    /// falls back to `filterOptionsResult` when nil
    var filterOptionsHandler: ((String) -> Result<LibraryFilterOptions, Error>)?
    var narrowedOptionsRequests: [LibraryQuery] = []
    var narrowedOptionsResult: Result<LibraryFilterOptions?, Error> = .success(nil)
    /// Per-scan-query results; falls back to narrowedOptionsResult when nil
    var narrowedOptionsHandler: ((LibraryQuery) -> Result<LibraryFilterOptions?, Error>)?

    func authenticate(username: String, password _: String) async throws -> User {
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

    func getLibraries() async throws -> [Library] {
        try librariesResult.get()
    }

    func getLibraryItems(
        libraryId: String,
        itemTypes _: [MediaType]?,
        query: LibraryQuery,
        limit: Int,
        startIndex: Int,
    ) async throws -> MediaItemPage {
        let result: Result<MediaItemPage, Error> = lock.withLock {
            libraryItemsRequests.append((libraryId, query, limit, startIndex))
            let index = min(libraryItemsRequests.count - 1, libraryItemsPages.count - 1)
            return libraryItemsPages[index]
        }
        await libraryItemsDelay?()
        return try result.get()
    }

    func getLibraryFilterOptions(libraryId: String, itemTypes _: [MediaType]?) async throws -> LibraryFilterOptions {
        let result: Result<LibraryFilterOptions, Error> = lock.withLock {
            filterOptionsHandler?(libraryId) ?? filterOptionsResult
        }
        return try result.get()
    }

    func getLibraryFilterOptions(
        libraryId _: String,
        itemTypes _: [MediaType]?,
        matching query: LibraryQuery,
    ) async throws -> LibraryFilterOptions? {
        let result: Result<LibraryFilterOptions?, Error> = lock.withLock {
            narrowedOptionsRequests.append(query)
            return narrowedOptionsHandler?(query) ?? narrowedOptionsResult
        }
        return try result.get()
    }

    var mediaItemsById: [String: MediaItem] = [:]
    var mediaItemFailureIds: Set<String> = []
    var mediaItemRequests: [String] = []

    func getMediaItem(itemId: String) async throws -> MediaItem {
        try lock.withLock {
            mediaItemRequests.append(itemId)
            if mediaItemFailureIds.contains(itemId) {
                throw APIError.generic("Item fetch failed")
            }
            return mediaItemsById[itemId] ?? MediaItem(id: itemId, name: "Item", type: .movie)
        }
    }

    var similarItemsResult: Result<[MediaItem], Error> = .success([])

    func getSimilarItems(itemId _: String, limit _: Int?) async throws -> [MediaItem] {
        try similarItemsResult.get()
    }

    func searchItems(query: String, limit _: Int?) async throws -> [MediaItem] {
        searchQueries.append(query)
        return try searchResult.get()
    }

    func getImageURL(itemId _: String, imageType _: ImageType, maxWidth _: Int?, maxHeight _: Int?) -> URL {
        serverURL
    }

    func getPerson(personId _: String) async throws -> Person {
        try personResult.get()
    }

    /// Per-shelf results keyed by the requested item types (the person page
    /// fans its three shelves out concurrently); nil handler serves []
    var itemsFeaturingPersonHandler: (([MediaType]) -> Result<[MediaItem], Error>)?

    func getItemsFeaturingPerson(
        personId: String,
        itemTypes: [MediaType],
        personTypes _: [String]?,
        limit _: Int?,
    ) async throws -> [MediaItem] {
        let result: Result<[MediaItem], Error> = lock.withLock {
            itemsFeaturingPersonRequests.append((personId, itemTypes))
            return itemsFeaturingPersonHandler?(itemTypes) ?? .success([])
        }
        return try result.get()
    }

    var collectionItemsRequests: [String] = []
    var collectionItemsResult: Result<[MediaItem], Error> = .success([])

    func getCollectionItems(collectionId: String) async throws -> [MediaItem] {
        collectionItemsRequests.append(collectionId)
        return try collectionItemsResult.get()
    }

    var resumeItemsResult: Result<[MediaItem], Error> = .success([])

    func getResumeItems(limit _: Int?) async throws -> [MediaItem] {
        try resumeItemsResult.get()
    }

    /// Latest requests by libraryId (nil = the global hero-source fetch);
    /// lock-guarded because the per-library fetches fan out in a task group
    var latestItemsRequests: [String?] = []
    /// Per-library results, keyed the same way; nil handler serves []
    var latestItemsHandler: ((String?) -> Result<[MediaItem], Error>)?

    /// Optional gate awaited before serving latest items, for in-flight tests
    var latestItemsDelay: (() async -> Void)?

    func getLatestItems(libraryId: String?, limit _: Int?) async throws -> [MediaItem] {
        let result: Result<[MediaItem], Error> = lock.withLock {
            latestItemsRequests.append(libraryId)
            return latestItemsHandler?(libraryId) ?? .success([])
        }
        await latestItemsDelay?()
        return try result.get()
    }

    func getPlaybackInfo(
        itemId: String,
        startTimeTicks: Int64?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws -> PlaybackSessionInfo {
        playbackInfoRequests.append((itemId, startTimeTicks, audioStreamIndex, subtitleStreamIndex))
        return try playbackInfoResult.get()
    }

    func resolveStream(for source: MediaSource, parameters: StreamParameters) throws -> StreamResolution {
        // Route through the real decision rule so tests exercise it end to end
        let method = source.playMethod(
            audioStreamIndex: parameters.audioStreamIndex,
            subtitleStreamIndex: parameters.subtitleStreamIndex,
        )
        streamResolutions.append((source.id, parameters, method))
        return StreamResolution(
            url: URL(string: "https://example.com/Videos/\(parameters.itemId)/stream")!,
            playMethod: method,
        )
    }

    func reportPlaybackStart(
        itemId: String,
        mediaSourceId _: String?,
        playSessionId _: String?,
        positionTicks: Int64,
        playMethod: PlayMethod,
        audioStreamIndex _: Int?,
        subtitleStreamIndex _: Int?,
    ) async throws {
        startReports.append((itemId, positionTicks, playMethod))
    }

    func reportPlaybackProgress(
        itemId: String,
        mediaSourceId _: String?,
        playSessionId _: String?,
        positionTicks: Int64,
        playMethod: PlayMethod,
        isPaused: Bool,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws {
        progressReports.append((itemId, positionTicks, isPaused, playMethod, audioStreamIndex, subtitleStreamIndex))
    }

    func reportPlaybackStopped(
        itemId: String,
        mediaSourceId _: String?,
        playSessionId _: String?,
        positionTicks: Int64,
    ) async throws {
        stopReports.append((itemId, positionTicks))
    }

    func getNextEpisode(after episode: MediaItem) async throws -> MediaItem? {
        nextEpisodeRequests.append(episode.id)
        return nextEpisodeResult
    }

    var seasonsResult: Result<[MediaItem], Error> = .success([])

    func getSeasons(seriesId _: String) async throws -> [MediaItem] {
        try seasonsResult.get()
    }

    var episodesResult: Result<[MediaItem], Error> = .success([])
    var episodesRequests: [String] = []

    func getEpisodes(seriesId: String, seasonId _: String?) async throws -> [MediaItem] {
        let result: Result<[MediaItem], Error> = lock.withLock {
            episodesRequests.append(seriesId)
            return episodesResult
        }
        return try result.get()
    }

    var nextUpEpisodesBySeries: [String: MediaItem] = [:]
    var nextUpEpisodeRequests: [String] = []
    /// When set, `getNextUpEpisode` throws — for proving next-up failures
    /// are enrichment (they must not fail a page)
    var nextUpEpisodeError: Error?

    func getNextUpEpisode(seriesId: String) async throws -> MediaItem? {
        lock.withLock { nextUpEpisodeRequests.append(seriesId) }
        if let nextUpEpisodeError {
            throw nextUpEpisodeError
        }
        return nextUpEpisodesBySeries[seriesId]
    }

    var nextUpItemsResult: Result<[MediaItem], Error> = .success([])

    func getNextUpItems(limit _: Int?) async throws -> [MediaItem] {
        try nextUpItemsResult.get()
    }

    func markPlayed(itemId _: String) async throws {}
    func markUnplayed(itemId _: String) async throws {}
    func markFavorite(itemId _: String) async throws {}
    func unmarkFavorite(itemId _: String) async throws {}
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
            userData: resumeTicks.map { UserData(playbackPositionTicks: $0) },
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
            progressInterval: .milliseconds(50),
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

    // MARK: - Direct Play

    private func stubDirectPlaySource(on client: MockJellyfinClient) {
        client.playbackInfoResult = .success(
            PlaybackSessionInfo(
                playSessionId: "session-1",
                mediaSources: [
                    MediaSource(
                        id: "source-1",
                        container: "mp4",
                        supportsDirectPlay: true,
                        supportsDirectStream: true,
                        supportsTranscoding: true,
                    ),
                ],
            ),
        )
    }

    @Test("Direct-play-capable sources start and report direct play")
    func directPlayCapableSourceDirectPlays() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(client.streamResolutions.count == 1)
        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(client.startReports.count == 1)
        #expect(client.startReports[0].playMethod == .directPlay)
    }

    @Test("The default mock source still transcodes (existing behavior preserved)")
    func incompatibleSourceTranscodes() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.streamResolutions.count == 1)
        #expect(client.streamResolutions[0].playMethod == .transcode)
        #expect(client.startReports[0].playMethod == .transcode)
    }

    @Test("Selecting a subtitle on a direct session falls back to HLS; clearing stays in place")
    func subtitleSelectionLeavesDirectPlay() async throws {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        #expect(client.startReports[0].playMethod == .directPlay)

        await viewModel.selectSubtitleStream(index: 3)
        #expect(viewModel.state == .playing)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].playMethod == .directStream)
        #expect(client.streamResolutions[1].parameters.subtitleStreamIndex == 3)
        #expect(client.startReports[1].playMethod == .directStream)

        // Turning subtitles off inside an HLS session is an in-place media
        // selection, not a rebuild: the session stays on HLS and the
        // deselection is reported through progress
        let progressCountBefore = client.progressReports.count
        await viewModel.selectSubtitleStream(index: nil)
        #expect(client.streamResolutions.count == 2)
        #expect(client.startReports.count == 2)
        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        #expect(client.progressReports.count > progressCountBefore)
        let lastProgress = try #require(client.progressReports.last)
        #expect(lastProgress.subtitleStreamIndex == nil)
        #expect(lastProgress.playMethod == .directStream)
    }

    @Test("Resume works on a direct-play source")
    func resumeOnDirectPlay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        let resumeTicks: Int64 = 6_000_000_000
        let viewModel = PlaybackViewModel(client: client, item: makeMovie(resumeTicks: resumeTicks))

        await viewModel.start()

        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(client.startReports[0].positionTicks == resumeTicks)
        #expect(client.startReports[0].playMethod == .directPlay)
    }

    // MARK: - Subtitle Selection

    private static let englishSrt = MediaStreamInfo(
        index: 2,
        type: .subtitle,
        displayTitle: "English - Default - SUBRIP",
        language: "eng",
        codec: "subrip",
        isDefault: true,
        isTextSubtitleStream: true,
    )
    private static let spanishSrt = MediaStreamInfo(
        index: 3,
        type: .subtitle,
        displayTitle: "Spanish - SUBRIP",
        language: "spa",
        codec: "subrip",
        isTextSubtitleStream: true,
    )
    private static let englishPgs = MediaStreamInfo(
        index: 4,
        type: .subtitle,
        displayTitle: "English - PGSSUB",
        language: "eng",
        codec: "pgssub",
        isTextSubtitleStream: false,
    )

    private func stubSubtitledSource(
        on client: MockJellyfinClient,
        directPlay: Bool = true,
        defaultSubtitleStreamIndex: Int? = nil,
    ) {
        client.playbackInfoResult = .success(
            PlaybackSessionInfo(
                playSessionId: "session-1",
                mediaSources: [
                    MediaSource(
                        id: "source-1",
                        container: "mp4",
                        supportsDirectPlay: directPlay,
                        supportsDirectStream: true,
                        supportsTranscoding: true,
                        defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
                        subtitleStreams: [Self.englishSrt, Self.spanishSrt, Self.englishPgs],
                    ),
                ],
            ),
        )
    }

    @Test("start() seeds the server's default subtitle selection")
    func startSeedsDefaultSubtitle() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 2)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.selectedSubtitleStreamIndex == 2)
        #expect(client.streamResolutions[0].parameters.subtitleStreamIndex == 2)
        // Delivering the default subtitle needs HLS even on a
        // direct-play-capable source
        #expect(client.streamResolutions[0].playMethod == .directStream)
    }

    @Test("An explicit off is not re-seeded by rebuilds")
    func explicitOffSurvivesRebuild() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 2)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)
        #expect(viewModel.selectedSubtitleStreamIndex == nil)

        // An audio change forces a rebuild; the explicit off must stick
        await viewModel.selectAudioStream(index: 9)

        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        let lastResolution = client.streamResolutions.last
        #expect(lastResolution?.parameters.subtitleStreamIndex == Int??.some(nil))
    }

    @Test("Autoplay resets the selection so the next episode reseeds")
    func autoplayReseedsDefaultSubtitle() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 2)
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)
        await viewModel.handlePlaybackEnded()
        await viewModel.playNextEpisodeNow()

        #expect(viewModel.selectedSubtitleStreamIndex == 2)
    }

    @Test("Selecting an image subtitle transcodes for burn-in and rebuilds out of it")
    func imageSubtitleBurnInTransitions() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        #expect(client.startReports[0].playMethod == .directPlay)

        await viewModel.selectSubtitleStream(index: 4)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].playMethod == .transcode)
        #expect(client.startReports[1].playMethod == .transcode)

        // Removing a burned-in track requires another rebuild — the video
        // itself has the subtitles composited in
        await viewModel.selectSubtitleStream(index: nil)
        #expect(client.streamResolutions.count == 3)
        #expect(client.streamResolutions[2].playMethod == .directPlay)
        #expect(client.startReports[2].playMethod == .directPlay)
    }

    @Test("A matched text target switches in place without a rebuild")
    func cheapSwitchBetweenTextTracks() async throws {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false, defaultSubtitleStreamIndex: 2)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        #expect(client.streamResolutions[0].playMethod == .directStream)
        let playerBefore = viewModel.player

        // Simulate the legible group having loaded from the master playlist
        viewModel.legibleOptions = [
            LegibleOption(position: 0, displayName: "English - Default - SUBRIP", languageTag: "en"),
            LegibleOption(position: 1, displayName: "Spanish - SUBRIP", languageTag: "es"),
        ]

        await viewModel.selectSubtitleStream(index: 3)

        #expect(viewModel.selectedSubtitleStreamIndex == 3)
        #expect(client.playbackInfoRequests.count == 1)
        #expect(client.streamResolutions.count == 1)
        #expect(client.startReports.count == 1)
        #expect(viewModel.player === playerBefore)
        let lastProgress = try #require(client.progressReports.last)
        #expect(lastProgress.subtitleStreamIndex == 3)
        #expect(lastProgress.playMethod == .directStream)
    }

    @Test("An unmatched text target falls back to a rebuild")
    func unmatchedTargetRebuilds() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false, defaultSubtitleStreamIndex: 2)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        // Legible options never loaded (empty) → no confident match
        await viewModel.selectSubtitleStream(index: 3)

        #expect(client.playbackInfoRequests.count == 2)
        #expect(client.playbackInfoRequests[1].subtitleStreamIndex == 3)
        #expect(client.startReports.count == 2)
    }

    @Test("In-place switch decision matrix")
    func canSwitchInPlaceMatrix() {
        typealias Decide = (Bool, PlayMethod, Bool, Bool, Bool, Bool) -> Bool
        let decide: Decide = PlaybackViewModel.canSwitchSubtitlesInPlace

        // (hasPlayer, currentMethod, sessionUsesBurnIn, targetRequiresBurnIn, turningOff, targetMatched)
        #expect(decide(true, .directStream, false, false, true, false)) // off in HLS
        #expect(decide(true, .directStream, false, false, false, true)) // matched text in HLS
        #expect(decide(true, .transcode, false, false, false, true)) // matched text while transcoding
        #expect(!decide(false, .directStream, false, false, true, false)) // no player
        #expect(!decide(true, .directPlay, false, false, false, true)) // direct play has no renditions
        #expect(!decide(true, .transcode, true, false, true, false)) // leaving burn-in
        #expect(!decide(true, .directStream, false, true, false, true)) // entering burn-in
        #expect(!decide(true, .directStream, false, false, false, false)) // unmatched target
    }
}

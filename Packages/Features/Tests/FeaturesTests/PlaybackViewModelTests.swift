import AVFoundation
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

    func getImageURL(itemId: String, imageType: ImageType, maxWidth _: Int?, maxHeight _: Int?) -> URL {
        // Real-shaped path so tests can assert WHICH image a view model chose
        serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Images")
            .appendingPathComponent(imageType.rawValue)
    }

    /// Image-info responses by item id; ids absent from the map serve []
    var imageInfosById: [String: [ItemImageInfo]] = [:]
    var imageInfoFailureIds: Set<String> = []
    var imageInfoRequests: [String] = []

    func getImageInfo(itemId: String) async throws -> [ItemImageInfo] {
        try lock.withLock {
            imageInfoRequests.append(itemId)
            if imageInfoFailureIds.contains(itemId) {
                throw APIError.generic("Image info fetch failed")
            }
            return imageInfosById[itemId] ?? []
        }
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

    func resolveStream(
        for source: MediaSource,
        parameters: StreamParameters,
        assumeInterposer _: Bool,
    ) throws -> StreamResolution {
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

    var playbackExtrasRequests: [String] = []
    var playbackExtrasResult: Result<PlaybackExtras, Error> = .success(PlaybackExtras())

    func getPlaybackExtras(itemId: String) async throws -> PlaybackExtras {
        lock.withLock { playbackExtrasRequests.append(itemId) }
        return try playbackExtrasResult.get()
    }

    func chapterImageURL(itemId: String, chapterIndex: Int, tag: String, maxWidth: Int?) -> URL {
        var url = serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Images")
            .appendingPathComponent("Chapter")
            .appendingPathComponent(String(chapterIndex))
        var queryItems = [URLQueryItem(name: "tag", value: tag)]
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        url.append(queryItems: queryItems)
        return url
    }

    func trickplayTileURL(itemId: String, width: Int, tileIndex: Int, mediaSourceId: String?) -> URL? {
        var url = serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Trickplay")
            .appendingPathComponent(String(width))
            .appendingPathComponent("\(tileIndex).jpg")
        if let mediaSourceId {
            url.append(queryItems: [URLQueryItem(name: "MediaSourceId", value: mediaSourceId)])
        }
        return url
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

    var recentlyPlayedEpisodesResult: Result<[MediaItem], Error> = .success([])

    func getRecentlyPlayedEpisodes(limit _: Int?) async throws -> [MediaItem] {
        try recentlyPlayedEpisodesResult.get()
    }

    /// Recorded user-data mutations, as ("played"/"unplayed"/"favorite"/
    /// "unfavorite", itemId); `userDataError` makes them all throw
    var userDataCalls: [(action: String, itemId: String)] = []
    var userDataError: Error?

    private func recordUserData(_ action: String, _ itemId: String) throws {
        try lock.withLock {
            userDataCalls.append((action, itemId))
            if let userDataError {
                throw userDataError
            }
        }
    }

    func markPlayed(itemId: String) async throws {
        try recordUserData("played", itemId)
    }

    func markUnplayed(itemId: String) async throws {
        try recordUserData("unplayed", itemId)
    }

    func markFavorite(itemId: String) async throws {
        try recordUserData("favorite", itemId)
    }

    func unmarkFavorite(itemId: String) async throws {
        try recordUserData("unfavorite", itemId)
    }
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

    /// Poll until the condition holds (bounded), so timer-driven assertions stay
    /// fast when healthy and tolerant when the machine is loaded. A fixed sleep
    /// would measure wall-clock the test does not control, which flakes on CI.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Progress is reported periodically")
    func progressReporting() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(
            client: client,
            item: makeMovie(),
            progressInterval: .milliseconds(50),
        )

        await viewModel.start()
        await waitUntil { client.progressReports.count >= 2 }
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

    // MARK: - Trickplay

    private func makeTrickplayInfo() -> TrickplayInfo {
        TrickplayInfo(
            widthKey: 320, thumbnailWidth: 320, thumbnailHeight: 180,
            columns: 10, rows: 10, intervalMilliseconds: 10000, thumbnailCount: 60,
        )
    }

    private func assetURL(of viewModel: PlaybackViewModel) -> URL? {
        (viewModel.player?.currentItem?.asset as? AVURLAsset)?.url
    }

    @Test("start() requests the playback extras for the item")
    func startRequestsPlaybackExtras() async {
        let client = MockJellyfinClient()
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.playbackExtrasRequests == ["movie-1"])
        // No extras (the default stub) → the loopback server still
        // interposes: subtitle-playlist rewriting needs it on every HLS
        // session, trickplay or not
        #expect(assetURL(of: viewModel)?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    @Test("HLS playback with trickplay data interposes the loopback master")
    func trickplayInterposesMaster() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: ["source-1": [makeTrickplayInfo()]]),
        ))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        let url = assetURL(of: viewModel)
        #expect(url?.host() == "127.0.0.1")
        #expect(url?.lastPathComponent == "master.m3u8")
        await viewModel.stop()
    }

    @Test("A playback-extras fetch failure still interposes, minus thumbnails")
    func playbackExtrasFailureDegrades() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .failure(APIError.generic("boom"))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(assetURL(of: viewModel)?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    @Test("Direct play never interposes, even with trickplay data")
    func directPlaySkipsTrickplay() async {
        let client = MockJellyfinClient()
        stubDirectPlaySource(on: client)
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: ["source-1": [makeTrickplayInfo()]]),
        ))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(client.streamResolutions[0].playMethod == .directPlay)
        #expect(assetURL(of: viewModel)?.host() == "example.com")
    }

    @Test("A manifest keyed to other media sources interposes without thumbnails")
    func mismatchedManifestSourceDegrades() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(
            trickplay: TrickplayManifest(sources: [
                "other-source": [makeTrickplayInfo()],
                "another-source": [makeTrickplayInfo()],
            ]),
        ))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.state == .playing)
        #expect(assetURL(of: viewModel)?.host() == "127.0.0.1")
        await viewModel.stop()
    }

    // MARK: - Chapters & metadata

    private func makeChapters() -> [Chapter] {
        [
            Chapter(name: "One", startTicks: 0, imageIndex: 0),
            // 3600s into makeMovie()'s 7200s runtime
            Chapter(name: "Two", startTicks: 36_000_000_000, imageIndex: 1),
        ]
    }

    @Test("Chapters attach navigation markers and metadata to the player item")
    func chaptersAttachMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        let playerItem = try #require(viewModel.player?.currentItem)
        #if os(tvOS)
            let group = try #require(playerItem.navigationMarkerGroups.first)
            #expect(group.title == nil)
            #expect(group.timedNavigationMarkers?.count == 2)
        #endif
        #expect(!playerItem.externalMetadata.isEmpty)
    }

    @Test("A stream rebuild re-attaches markers without refetching extras")
    func rebuildReattachesMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        let originalItem = viewModel.player?.currentItem

        await viewModel.selectAudioStream(index: 2)

        let rebuiltItem = try #require(viewModel.player?.currentItem)
        #expect(rebuiltItem !== originalItem)
        #expect(client.playbackExtrasRequests == ["movie-1"])
        #if os(tvOS)
            #expect(rebuiltItem.navigationMarkerGroups.first?.timedNavigationMarkers?.count == 2)
        #endif
        #expect(!rebuiltItem.externalMetadata.isEmpty)
    }

    @Test("Autoplaying the next episode refetches extras for the new item")
    func autoplayRefetchesExtras() async {
        let client = MockJellyfinClient()
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.handlePlaybackEnded()
        await viewModel.playNextEpisodeNow()

        #expect(client.playbackExtrasRequests == ["ep-1", "ep-2"])
    }

    @Test("Cast members are published from the extras fetch")
    func castMembersFromExtras() async {
        let client = MockJellyfinClient()
        let member = CastMember(id: "p1", name: "Actor", role: "Lead", kind: "Actor", primaryImageTag: nil)
        client.playbackExtrasResult = .success(PlaybackExtras(people: [member]))
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.castMembers == [member])
    }

    @Test("A failed extras fetch falls back to the launching item's people")
    func castMembersFallBackToItem() async {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .failure(APIError.generic("boom"))
        let member = CastMember(id: "p2", name: "Actor", role: nil, kind: "Director", primaryImageTag: nil)
        let item = MediaItem(id: "movie-1", name: "Test Movie", type: .movie, people: [member])
        let viewModel = PlaybackViewModel(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.castMembers == [member])
    }

    @Test("An item without runtime still plays, just without markers")
    func missingRuntimeSkipsMarkers() async throws {
        let client = MockJellyfinClient()
        client.playbackExtrasResult = .success(PlaybackExtras(chapters: makeChapters()))
        let item = MediaItem(id: "movie-1", name: "No Runtime", type: .movie)
        let viewModel = PlaybackViewModel(client: client, item: item)

        await viewModel.start()

        #expect(viewModel.state == .playing)
        let playerItem = try #require(viewModel.player?.currentItem)
        #if os(tvOS)
            #expect(playerItem.navigationMarkerGroups.isEmpty)
        #endif
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

    @Test("Selecting a subtitle on a direct session falls back to HLS; clearing returns to it")
    func subtitleSelectionLeavesDirectPlay() async {
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

        // Turning subtitles off rebuilds rather than deselecting in place:
        // staying put strands the session on the subtitle-shaped stream
        // (TS/H.264), and rebuilding wins back direct play of the original
        // file, which HLS was only ever a detour from.
        await viewModel.selectSubtitleStream(index: nil)
        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        #expect(client.streamResolutions.count == 3)
        #expect(client.streamResolutions[2].playMethod == .directPlay)
        #expect(client.streamResolutions[2].parameters.subtitleStreamIndex == Int??.some(nil))
        #expect(client.startReports.count == 3)
        #expect(client.startReports[2].playMethod == .directPlay)
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

    @Test("A text default is not seeded — AVKit owns text subtitles")
    func startLeavesTextDefaultToAVKit() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 2)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        // The master advertises the rendition DEFAULT=YES; AVKit plus the
        // viewer's system caption preference decide auto-on natively, and
        // reconciliation adopts whatever it picks
        #expect(viewModel.selectedSubtitleStreamIndex == nil)
        #expect(client.streamResolutions[0].parameters.subtitleStreamIndex == Int??.some(nil))
        #expect(client.streamResolutions[0].playMethod == .directPlay)
    }

    @Test("A burn-in default is seeded — only the app can honor it")
    func startSeedsBurnInDefault() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 4)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
        #expect(client.streamResolutions[0].parameters.subtitleStreamIndex == 4)
        // Burn-in composites server-side, which is always a transcode
        #expect(client.streamResolutions[0].playMethod == .transcode)
    }

    @Test("An explicit off is not re-seeded by rebuilds")
    func explicitOffSurvivesRebuild() async {
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 4)
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
        stubSubtitledSource(on: client, defaultSubtitleStreamIndex: 4)
        let episode = MediaItem(id: "ep-1", name: "Episode 1", type: .episode, seriesId: "series-1")
        client.nextEpisodeResult = MediaItem(id: "ep-2", name: "Episode 2", type: .episode, seriesId: "series-1")
        let viewModel = PlaybackViewModel(client: client, item: episode)

        await viewModel.start()
        await viewModel.selectSubtitleStream(index: nil)
        await viewModel.handlePlaybackEnded()
        await viewModel.playNextEpisodeNow()

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
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

    @Test("Every app-menu subtitle change rebuilds the stream")
    func appMenuSubtitleChangesRebuild() async {
        // Post-#90 the app's menu carries only burn-in tracks, and burning
        // a track in or out of the video is always a server-side re-encode.
        // There is no in-place path left — and none may be added that calls
        // select(nil) on the legible group, which latches AVKit's subtitle
        // display off process-wide (#91).
        let client = MockJellyfinClient()
        stubSubtitledSource(on: client, directPlay: false, defaultSubtitleStreamIndex: nil)
        let viewModel = PlaybackViewModel(client: client, item: makeMovie())

        await viewModel.start()
        let playerBefore = viewModel.player

        await viewModel.selectSubtitleStream(index: 4)

        #expect(viewModel.selectedSubtitleStreamIndex == 4)
        #expect(client.playbackInfoRequests.count == 2)
        #expect(client.streamResolutions.count == 2)
        #expect(client.streamResolutions[1].parameters.subtitleStreamIndex == 4)
        #expect(client.startReports.count == 2)
        #expect(viewModel.player !== playerBefore)
    }
}

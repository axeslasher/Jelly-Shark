import Foundation
import JellyfinKit

/// The shared `JellyfinClientProtocol` stub for the Features test suites —
/// Search, Home, Library, MediaDetail, PersonDetail, GenreShelves, GenreCard,
/// ServerConnection and Playback. Every protocol method is stubbed here, with
/// per-suite response hooks and recorded-call arrays for assertions.
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
    /// Search calls in arrival order. Each search now fans out one query per
    /// item type, so the types are recorded alongside the term.
    var searchQueries: [(query: String, itemTypes: [MediaType])] = []
    /// Served (filtered to the requested types) when `searchHandler` is nil
    var searchResult: Result<[MediaItem], Error> = .success([])
    var personResult: Result<Person, Error> = .success(Person(id: "person-id", name: "Person"))
    var itemsFeaturingPersonRequests: [(personId: String, itemTypes: [MediaType])] = []
    var libraryItemsRequests: [(
        libraryId: String?,
        itemTypes: [MediaType]?,
        query: LibraryQuery,
        limit: Int,
        startIndex: Int,
    )] = []
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
    /// Library scopes the full-options endpoint was asked about, in order;
    /// nil is the unscoped (every library) request
    var filterOptionsRequests: [String?] = []
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
        libraryId: String?,
        itemTypes: [MediaType]?,
        query: LibraryQuery,
        limit: Int,
        startIndex: Int,
    ) async throws -> MediaItemPage {
        let result: Result<MediaItemPage, Error> = lock.withLock {
            libraryItemsRequests.append((libraryId, itemTypes, query, limit, startIndex))
            let index = min(libraryItemsRequests.count - 1, libraryItemsPages.count - 1)
            return libraryItemsPages[index]
        }
        await libraryItemsDelay?()
        return try result.get()
    }

    func getLibraryFilterOptions(libraryId: String?, itemTypes _: [MediaType]?) async throws -> LibraryFilterOptions {
        let result: Result<LibraryFilterOptions, Error> = lock.withLock {
            filterOptionsRequests.append(libraryId)
            return libraryId.flatMap { filterOptionsHandler?($0) } ?? filterOptionsResult
        }
        return try result.get()
    }

    func getLibraryFilterOptions(
        libraryId _: String?,
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

    /// Per-shelf results keyed by the requested item types (search fans its
    /// three shelves out concurrently, so one type can be made to fail on its
    /// own); nil handler filters `searchResult` by the requested types
    var searchHandler: (([MediaType]) -> Result<[MediaItem], Error>)?

    func searchItems(query: String, itemTypes: [MediaType], limit _: Int?) async throws -> [MediaItem] {
        // Takes the lock: three concurrent calls per search would race the
        // recording array otherwise.
        let result: Result<[MediaItem], Error> = lock.withLock {
            searchQueries.append((query, itemTypes))
            if let searchHandler {
                return searchHandler(itemTypes)
            }
            return searchResult.map { items in
                items.filter { itemTypes.contains($0.type) }
            }
        }
        return try result.get()
    }

    /// Counted, not just recorded: the search empty state must seed itself
    /// exactly once per view-model lifetime, however many times it attaches
    var searchSuggestionsCallCount = 0
    var searchSuggestionsResult: Result<[MediaItem], Error> = .success([])

    func getSearchSuggestions(limit _: Int?) async throws -> [MediaItem] {
        let result: Result<[MediaItem], Error> = lock.withLock {
            searchSuggestionsCallCount += 1
            return searchSuggestionsResult
        }
        return try result.get()
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

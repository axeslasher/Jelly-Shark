import Foundation
@testable import JellyfinKit

struct StubError: Error {}

/// Minimal `JellyfinClientProtocol` double for `CachingJellyfinClient`
/// tests. Only the methods the decorator adds behavior to are stubbed with
/// results; everything else traps, so an unexpected pass-through fails
/// loudly instead of silently succeeding.
final class StubJellyfinClient: JellyfinClientProtocol, @unchecked Sendable {
    let serverURL: URL
    var currentUser: User?
    var isAuthenticated: Bool {
        currentUser != nil
    }

    var accessToken: String? {
        currentUser == nil ? nil : "stub-token"
    }

    init(
        serverURL: URL = URL(string: "https://demo.example.org")!,
        currentUser: User? = nil,
    ) {
        self.serverURL = serverURL
        self.currentUser = currentUser
    }

    // MARK: - Stubbed results

    var userResult: User?
    var librariesResult: [Library] = []
    var libraryItemsResult = MediaItemPage(items: [], startIndex: 0, totalRecordCount: 0)
    var mediaItemResult: MediaItem?
    var resumeItemsResult: [MediaItem] = []
    var episodesResult: [MediaItem] = []
    /// Thrown by every mark* call when set, so failure paths can be tested
    var markError: Error?

    // MARK: - Recordings

    private(set) var markPlayedCalls: [String] = []
    private(set) var markUnplayedCalls: [String] = []
    private(set) var markFavoriteCalls: [String] = []
    private(set) var unmarkFavoriteCalls: [String] = []

    // MARK: - Stubbed methods

    func authenticate(username _: String, password _: String) async throws -> User {
        guard let userResult else { throw StubError() }
        currentUser = userResult
        return userResult
    }

    func signOut() async {
        currentUser = nil
    }

    func fetchCurrentUser() async throws -> User {
        guard let userResult else { throw StubError() }
        currentUser = userResult
        return userResult
    }

    func getLibraries() async throws -> [Library] {
        librariesResult
    }

    func getLibraryItems(
        libraryId _: String?,
        itemTypes _: [MediaType]?,
        query _: LibraryQuery,
        limit _: Int,
        startIndex _: Int,
    ) async throws -> MediaItemPage {
        libraryItemsResult
    }

    func getMediaItem(itemId _: String) async throws -> MediaItem {
        guard let mediaItemResult else { throw StubError() }
        return mediaItemResult
    }

    func getResumeItems(limit _: Int?) async throws -> [MediaItem] {
        resumeItemsResult
    }

    func getEpisodes(seriesId _: String, seasonId _: String?) async throws -> [MediaItem] {
        episodesResult
    }

    func markPlayed(itemId: String) async throws {
        if let markError {
            throw markError
        }
        markPlayedCalls.append(itemId)
    }

    func markUnplayed(itemId: String) async throws {
        if let markError {
            throw markError
        }
        markUnplayedCalls.append(itemId)
    }

    func markFavorite(itemId: String) async throws {
        if let markError {
            throw markError
        }
        markFavoriteCalls.append(itemId)
    }

    func unmarkFavorite(itemId: String) async throws {
        if let markError {
            throw markError
        }
        unmarkFavoriteCalls.append(itemId)
    }

    // MARK: - Unstubbed (trap on use)

    func getLibraryFilterOptions(libraryId _: String?, itemTypes _: [MediaType]?) async throws -> LibraryFilterOptions {
        fatalError("unstubbed getLibraryFilterOptions")
    }

    func getLibraryFilterOptions(
        libraryId _: String?,
        itemTypes _: [MediaType]?,
        matching _: LibraryQuery,
    ) async throws -> LibraryFilterOptions? {
        fatalError("unstubbed getLibraryFilterOptions(matching:)")
    }

    func getCollectionItems(collectionId _: String) async throws -> [MediaItem] {
        fatalError("unstubbed getCollectionItems")
    }

    func getSimilarItems(itemId _: String, limit _: Int?) async throws -> [MediaItem] {
        fatalError("unstubbed getSimilarItems")
    }

    func searchItems(query _: String, itemTypes _: [MediaType], limit _: Int?) async throws -> [MediaItem] {
        fatalError("unstubbed searchItems")
    }

    func getSearchSuggestions(limit _: Int?) async throws -> [MediaItem] {
        fatalError("unstubbed getSearchSuggestions")
    }

    func getPerson(personId _: String) async throws -> Person {
        fatalError("unstubbed getPerson")
    }

    func getItemsFeaturingPerson(
        personId _: String,
        itemTypes _: [MediaType],
        personTypes _: [String]?,
        limit _: Int?,
    ) async throws -> [MediaItem] {
        fatalError("unstubbed getItemsFeaturingPerson")
    }

    func getImageURL(itemId _: String, imageType _: ImageType, maxWidth _: Int?, maxHeight _: Int?) -> URL {
        fatalError("unstubbed getImageURL")
    }

    func getImageInfo(itemId _: String) async throws -> [ItemImageInfo] {
        fatalError("unstubbed getImageInfo")
    }

    func getLatestItems(libraryId _: String?, limit _: Int?) async throws -> [MediaItem] {
        fatalError("unstubbed getLatestItems")
    }

    func getPlaybackInfo(
        itemId _: String,
        startTimeTicks _: Int64?,
        audioStreamIndex _: Int?,
        subtitleStreamIndex _: Int?,
        capabilities _: PlaybackCapabilities,
    ) async throws -> PlaybackSessionInfo {
        fatalError("unstubbed getPlaybackInfo")
    }

    func resolveStream(
        for _: MediaSource,
        parameters _: StreamParameters,
        capabilities _: PlaybackCapabilities,
        assumeInterposer _: Bool,
    ) throws -> StreamResolution {
        fatalError("unstubbed resolveStream")
    }

    func reportPlaybackStart(
        itemId _: String,
        mediaSourceId _: String?,
        playSessionId _: String?,
        positionTicks _: Int64,
        playMethod _: PlayMethod,
        audioStreamIndex _: Int?,
        subtitleStreamIndex _: Int?,
    ) async throws {
        fatalError("unstubbed reportPlaybackStart")
    }

    func reportPlaybackProgress(
        itemId _: String,
        mediaSourceId _: String?,
        playSessionId _: String?,
        positionTicks _: Int64,
        playMethod _: PlayMethod,
        isPaused _: Bool,
        audioStreamIndex _: Int?,
        subtitleStreamIndex _: Int?,
    ) async throws {
        fatalError("unstubbed reportPlaybackProgress")
    }

    func reportPlaybackStopped(
        itemId _: String,
        mediaSourceId _: String?,
        playSessionId _: String?,
        positionTicks _: Int64,
    ) async throws {
        fatalError("unstubbed reportPlaybackStopped")
    }

    func getPlaybackExtras(itemId _: String) async throws -> PlaybackExtras {
        fatalError("unstubbed getPlaybackExtras")
    }

    func chapterImageURL(itemId _: String, chapterIndex _: Int, tag _: String, maxWidth _: Int?) -> URL {
        fatalError("unstubbed chapterImageURL")
    }

    func trickplayTileURL(itemId _: String, width _: Int, tileIndex _: Int, mediaSourceId _: String?) -> URL? {
        fatalError("unstubbed trickplayTileURL")
    }

    func getNextEpisode(after _: MediaItem) async throws -> MediaItem? {
        fatalError("unstubbed getNextEpisode")
    }

    func getSeasons(seriesId _: String) async throws -> [MediaItem] {
        fatalError("unstubbed getSeasons")
    }

    func getNextUpEpisode(seriesId _: String) async throws -> MediaItem? {
        fatalError("unstubbed getNextUpEpisode")
    }

    func getNextUpItems(limit _: Int?) async throws -> [MediaItem] {
        fatalError("unstubbed getNextUpItems")
    }

    func getRecentlyPlayedEpisodes(limit _: Int?) async throws -> [MediaItem] {
        fatalError("unstubbed getRecentlyPlayedEpisodes")
    }
}

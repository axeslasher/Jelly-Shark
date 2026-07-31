import Foundation

/// A write-through decorator over any `JellyfinClientProtocol`: responses
/// worth rendering on the next cold start are persisted to a
/// `MediaCacheStore`, and the user data riding on *every* item-returning
/// fetch is ingested into the user-state table. One choke point instead of a
/// dozen forgettable call sites in view models.
///
/// What it persists — and only this:
/// - `.currentUser` on authenticate / fetchCurrentUser
/// - `.libraries` on getLibraries
/// - `.mediaDetail` on getMediaItem
/// - `.libraryFirstPage` on getLibraryItems, page 0 of the default query
///   (name ascending, unfiltered) — filtered, re-sorted, and follow-up
///   pages are never cached
/// - user-state rows after a successful mark(Un)Played / (un)markFavorite —
///   server-acknowledged state, never a local guess
///
/// Playback (streams, transcoding decisions, reporting) and auth tokens
/// pass straight through untouched: CLAUDE.md forbids caching them.
///
/// The scope is derived per call from the wrapped client's identity, so an
/// unauthenticated client simply never writes. Cache writes are awaited
/// before returning — a few milliseconds against the network call that just
/// completed — so a caller that re-fetches immediately reads its own write.
public final class CachingJellyfinClient: JellyfinClientProtocol, Sendable {
    private let inner: any JellyfinClientProtocol
    private let cache: MediaCacheStore

    /// The scope a restored session already knows at construction. The
    /// wrapped client's `currentUser` stays nil until `fetchCurrentUser`
    /// returns, and an instant-connect launch fetches *during* that window —
    /// without this, every cache write in it would silently no-op.
    private let fallbackScope: CacheScope?

    public init(
        wrapping inner: any JellyfinClientProtocol,
        cache: MediaCacheStore,
        scope: CacheScope? = nil,
    ) {
        self.inner = inner
        self.cache = cache
        fallbackScope = scope
    }

    // MARK: - Identity (pass-through)

    public var serverURL: URL {
        inner.serverURL
    }

    public var currentUser: User? {
        inner.currentUser
    }

    public var isAuthenticated: Bool {
        inner.isAuthenticated
    }

    public var accessToken: String? {
        inner.accessToken
    }

    /// Whose cache the wrapped client's responses belong to: the live
    /// client's user when known (authoritative), else the restored
    /// session's identity, else nil — an unauthenticated fresh client
    /// never writes
    private var scope: CacheScope? {
        guard let user = inner.currentUser else { return fallbackScope }
        return CacheScope(serverURL: inner.serverURL, userID: user.id)
    }

    /// Record the user data carried by a batch of fetched items
    @discardableResult
    private func ingesting(_ items: [MediaItem]) async -> [MediaItem] {
        if let scope, !items.isEmpty {
            await cache.ingestServerUserData(scope: scope, items: items)
        }
        return items
    }

    @discardableResult
    private func ingesting(_ item: MediaItem?) async -> MediaItem? {
        if let item {
            await ingesting([item])
        }
        return item
    }

    // MARK: - Authentication

    public func authenticate(username: String, password: String) async throws -> User {
        let user = try await inner.authenticate(username: username, password: password)
        await cache.write(user, scope: CacheScope(serverURL: inner.serverURL, userID: user.id), key: .currentUser)
        return user
    }

    public func signOut() async {
        await inner.signOut()
    }

    public func fetchCurrentUser() async throws -> User {
        let user = try await inner.fetchCurrentUser()
        await cache.write(user, scope: CacheScope(serverURL: inner.serverURL, userID: user.id), key: .currentUser)
        return user
    }

    // MARK: - Libraries

    public func getLibraries() async throws -> [Library] {
        let libraries = try await inner.getLibraries()
        if let scope {
            await cache.write(libraries, scope: scope, key: .libraries)
        }
        return libraries
    }

    public func getLibraryItems(
        libraryId: String?,
        itemTypes: [MediaType]?,
        query: LibraryQuery,
        limit: Int,
        startIndex: Int,
    ) async throws -> MediaItemPage {
        let page = try await inner.getLibraryItems(
            libraryId: libraryId,
            itemTypes: itemTypes,
            query: query,
            limit: limit,
            startIndex: startIndex,
        )
        if let scope {
            await cache.ingestServerUserData(scope: scope, items: page.items)
            if startIndex == 0, query.isDefaultBrowse {
                await cache.write(page, scope: scope, key: .libraryFirstPage(libraryID: libraryId))
            }
        }
        return page
    }

    public func getLibraryFilterOptions(
        libraryId: String?,
        itemTypes: [MediaType]?,
    ) async throws -> LibraryFilterOptions {
        try await inner.getLibraryFilterOptions(libraryId: libraryId, itemTypes: itemTypes)
    }

    public func getLibraryFilterOptions(
        libraryId: String?,
        itemTypes: [MediaType]?,
        matching query: LibraryQuery,
    ) async throws -> LibraryFilterOptions? {
        try await inner.getLibraryFilterOptions(libraryId: libraryId, itemTypes: itemTypes, matching: query)
    }

    public func getCollectionItems(collectionId: String) async throws -> [MediaItem] {
        try await ingesting(inner.getCollectionItems(collectionId: collectionId))
    }

    // MARK: - Media

    public func getMediaItem(itemId: String) async throws -> MediaItem {
        let item = try await inner.getMediaItem(itemId: itemId)
        if let scope {
            await cache.ingestServerUserData(scope: scope, items: [item])
            await cache.write(item, scope: scope, key: .mediaDetail(itemID: itemId))
        }
        return item
    }

    public func getSimilarItems(itemId: String, limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.getSimilarItems(itemId: itemId, limit: limit))
    }

    public func searchItems(query: String, itemTypes: [MediaType], limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.searchItems(query: query, itemTypes: itemTypes, limit: limit))
    }

    public func getSearchSuggestions(limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.getSearchSuggestions(limit: limit))
    }

    // MARK: - People

    public func getPerson(personId: String) async throws -> Person {
        try await inner.getPerson(personId: personId)
    }

    public func getItemsFeaturingPerson(
        personId: String,
        itemTypes: [MediaType],
        personTypes: [String]?,
        limit: Int?,
    ) async throws -> [MediaItem] {
        try await ingesting(inner.getItemsFeaturingPerson(
            personId: personId,
            itemTypes: itemTypes,
            personTypes: personTypes,
            limit: limit,
        ))
    }

    // MARK: - Images

    public func getImageURL(itemId: String, imageType: ImageType, maxWidth: Int?, maxHeight: Int?) -> URL {
        inner.getImageURL(itemId: itemId, imageType: imageType, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    public func getImageInfo(itemId: String) async throws -> [ItemImageInfo] {
        try await inner.getImageInfo(itemId: itemId)
    }

    // MARK: - Home sections

    public func getResumeItems(limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.getResumeItems(limit: limit))
    }

    public func getLatestItems(libraryId: String?, limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.getLatestItems(libraryId: libraryId, limit: limit))
    }

    // MARK: - Playback (never cached)

    public func getPlaybackInfo(
        itemId: String,
        startTimeTicks: Int64?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
        capabilities: PlaybackCapabilities,
    ) async throws -> PlaybackSessionInfo {
        try await inner.getPlaybackInfo(
            itemId: itemId,
            startTimeTicks: startTimeTicks,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            capabilities: capabilities,
        )
    }

    public func resolveStream(
        for source: MediaSource,
        parameters: StreamParameters,
        capabilities: PlaybackCapabilities,
        assumeInterposer: Bool,
    ) throws -> StreamResolution {
        try inner.resolveStream(
            for: source,
            parameters: parameters,
            capabilities: capabilities,
            assumeInterposer: assumeInterposer,
        )
    }

    public func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        playMethod: PlayMethod,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws {
        try await inner.reportPlaybackStart(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
            playMethod: playMethod,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
        )
    }

    public func reportPlaybackProgress(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        playMethod: PlayMethod,
        isPaused: Bool,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws {
        try await inner.reportPlaybackProgress(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
            playMethod: playMethod,
            isPaused: isPaused,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
        )
    }

    public func reportPlaybackStopped(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
    ) async throws {
        try await inner.reportPlaybackStopped(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
        )
    }

    public func getPlaybackExtras(itemId: String) async throws -> PlaybackExtras {
        let extras = try await inner.getPlaybackExtras(itemId: itemId)
        // Not an item-returning fetch, but it carries the freshest user data
        // the app ever sees for an item (user-scoped, fetched at playback
        // launch) — skipping it would leave the state stale for exactly the
        // items being watched. The trickplay/chapter payload itself is
        // playback data and stays uncached.
        if let data = extras.userData {
            await ingesting([MediaItem(id: itemId, name: "", type: .unknown, userData: data)])
        }
        return extras
    }

    public func chapterImageURL(itemId: String, chapterIndex: Int, tag: String, maxWidth: Int?) -> URL {
        inner.chapterImageURL(itemId: itemId, chapterIndex: chapterIndex, tag: tag, maxWidth: maxWidth)
    }

    public func trickplayTileURL(itemId: String, width: Int, tileIndex: Int, mediaSourceId: String?) -> URL? {
        inner.trickplayTileURL(itemId: itemId, width: width, tileIndex: tileIndex, mediaSourceId: mediaSourceId)
    }

    /// Explicitly forwarded: without this the decorator's witness would be
    /// the protocol's no-op default, and the real client's
    /// `DELETE /Videos/ActiveEncodings` would be silently swallowed,
    /// leaking server-side transcodes
    public func stopEncoding(playSessionId: String) async {
        await inner.stopEncoding(playSessionId: playSessionId)
    }

    // MARK: - Episodes

    public func getNextEpisode(after episode: MediaItem) async throws -> MediaItem? {
        try await ingesting(inner.getNextEpisode(after: episode))
    }

    public func getSeasons(seriesId: String) async throws -> [MediaItem] {
        try await ingesting(inner.getSeasons(seriesId: seriesId))
    }

    public func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        try await ingesting(inner.getEpisodes(seriesId: seriesId, seasonId: seasonId))
    }

    public func getNextUpEpisode(seriesId: String) async throws -> MediaItem? {
        try await ingesting(inner.getNextUpEpisode(seriesId: seriesId))
    }

    public func getNextUpItems(limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.getNextUpItems(limit: limit))
    }

    public func getRecentlyPlayedEpisodes(limit: Int?) async throws -> [MediaItem] {
        try await ingesting(inner.getRecentlyPlayedEpisodes(limit: limit))
    }

    // MARK: - User data

    public func markPlayed(itemId: String) async throws {
        try await inner.markPlayed(itemId: itemId)
        if let scope {
            await cache.setUserState(scope: scope, itemID: itemId) { state in
                // Mirrors MediaItem.settingPlayed: the server clears resume
                // progress on both transitions
                state.played = true
                state.playbackPositionTicks = nil
            }
        }
    }

    public func markUnplayed(itemId: String) async throws {
        try await inner.markUnplayed(itemId: itemId)
        if let scope {
            await cache.setUserState(scope: scope, itemID: itemId) { state in
                state.played = false
                state.playbackPositionTicks = nil
            }
        }
    }

    public func markFavorite(itemId: String) async throws {
        try await inner.markFavorite(itemId: itemId)
        if let scope {
            await cache.setUserState(scope: scope, itemID: itemId) { state in
                state.isFavorite = true
            }
        }
    }

    public func unmarkFavorite(itemId: String) async throws {
        try await inner.unmarkFavorite(itemId: itemId)
        if let scope {
            await cache.setUserState(scope: scope, itemID: itemId) { state in
                state.isFavorite = false
            }
        }
    }
}

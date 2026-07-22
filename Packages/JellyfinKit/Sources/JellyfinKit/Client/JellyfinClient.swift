import Foundation
import Get
import JellyfinAPI

/// Protocol defining the Jellyfin API client interface
/// This provides a clean, app-focused API that wraps the official Jellyfin SDK
public protocol JellyfinClientProtocol: Sendable {
    /// The base URL of the Jellyfin server
    var serverURL: URL { get }

    /// The authenticated user, if any
    var currentUser: User? { get }

    /// Whether the client is currently authenticated
    var isAuthenticated: Bool { get }

    /// The current access token, if authenticated
    var accessToken: String? { get }

    // MARK: - Authentication

    /// Authenticate with the Jellyfin server
    /// - Parameters:
    ///   - username: The username
    ///   - password: The password
    /// - Returns: The authenticated user
    func authenticate(username: String, password: String) async throws -> User

    /// Sign out and clear credentials
    func signOut() async

    /// Fetch the current user's profile from the server (GET /Users/{userId})
    ///
    /// Used to validate a restored session before treating it as authenticated.
    /// - Returns: The current user
    /// - Throws: `APIError.unauthorized` if the token is no longer valid
    func fetchCurrentUser() async throws -> User

    // MARK: - Libraries

    /// Fetch all libraries available to the current user
    /// - Returns: Array of libraries
    func getLibraries() async throws -> [Library]

    /// Fetch one page of items from a library
    /// - Parameters:
    ///   - libraryId: The library ID
    ///   - itemTypes: Which item kinds to return (e.g., `[.movie]`)
    ///   - query: Sort and filter selections
    ///   - limit: Page size
    ///   - startIndex: Starting index for pagination
    /// - Returns: The page of media items plus the total record count
    func getLibraryItems(
        libraryId: String,
        itemTypes: [MediaType]?,
        query: LibraryQuery,
        limit: Int,
        startIndex: Int,
    ) async throws -> MediaItemPage

    /// Fetch the filter values actually present in a library (genres,
    /// official ratings, years), for building filter menus
    func getLibraryFilterOptions(libraryId: String, itemTypes: [MediaType]?) async throws -> LibraryFilterOptions

    /// Compute the filter values still available under the given query by
    /// scanning the matching items, so menus can hide dead-end options
    /// - Returns: The narrowed options, or nil when the result set is too
    ///   large to scan (callers should fall back to the full options)
    func getLibraryFilterOptions(
        libraryId: String,
        itemTypes: [MediaType]?,
        matching query: LibraryQuery,
    ) async throws -> LibraryFilterOptions?

    /// Fetch the items inside a collection (BoxSet), in release order.
    /// Collections are folder items, so their children come from the same
    /// items endpoint as library grids (the id maps to `parentId`).
    /// - Parameter collectionId: The BoxSet item ID
    /// - Returns: The collection's items, sorted by premiere date
    func getCollectionItems(collectionId: String) async throws -> [MediaItem]

    // MARK: - Media

    /// Fetch details for a specific media item
    /// - Parameter itemId: The item ID
    /// - Returns: The media item details
    func getMediaItem(itemId: String) async throws -> MediaItem

    /// Fetch items similar to the given item ("More Like This")
    /// - Parameters:
    ///   - itemId: The item ID to find similar items for
    ///   - limit: Maximum number of items to return
    /// - Returns: Similar media items
    func getSimilarItems(itemId: String, limit: Int?) async throws -> [MediaItem]

    /// Search the user's libraries by name
    /// - Parameters:
    ///   - query: The search term
    ///   - limit: Maximum number of items to return
    /// - Returns: Matching media items (movies, series, episodes)
    func searchItems(query: String, limit: Int?) async throws -> [MediaItem]

    // MARK: - People

    /// Fetch a person's details. Persons are items on the server, so the ID
    /// is a regular item ID (headshots use the standard image endpoint).
    /// - Parameter personId: The person's item ID
    /// - Returns: The person's details
    func getPerson(personId: String) async throws -> Person

    /// Fetch items featuring a person, newest first
    /// - Parameters:
    ///   - personId: The person's item ID
    ///   - itemTypes: Which item kinds to return (e.g., `[.movie]`)
    ///   - personTypes: Credit-kind filter (e.g., `["Actor"]`); nil for any credit
    ///   - limit: Maximum number of items to return
    /// - Returns: Media items the person is credited on
    func getItemsFeaturingPerson(
        personId: String,
        itemTypes: [MediaType],
        personTypes: [String]?,
        limit: Int?,
    ) async throws -> [MediaItem]

    /// Get the image URL for a media item
    /// - Parameters:
    ///   - itemId: The item ID
    ///   - imageType: The type of image (primary, backdrop, etc.)
    ///   - maxWidth: Optional maximum width for the image
    ///   - maxHeight: Optional maximum height for the image
    /// - Returns: The image URL
    func getImageURL(itemId: String, imageType: ImageType, maxWidth: Int?, maxHeight: Int?) -> URL

    // MARK: - Resume

    /// Fetch items the user is currently watching (resume playback)
    /// - Parameter limit: Maximum number of items to return
    /// - Returns: Array of media items with playback progress
    func getResumeItems(limit: Int?) async throws -> [MediaItem]

    // MARK: - Latest

    /// Fetch latest items added to a library
    /// - Parameters:
    ///   - libraryId: The library ID (optional, nil for all libraries)
    ///   - limit: Maximum number of items to return
    /// - Returns: Array of recently added media items
    func getLatestItems(libraryId: String?, limit: Int?) async throws -> [MediaItem]

    // MARK: - Playback

    /// Fetch playback information for an item (media sources and play session)
    /// - Parameters:
    ///   - itemId: The item ID
    ///   - startTimeTicks: Intended start position in ticks
    ///   - audioStreamIndex: Preferred audio stream index
    ///   - subtitleStreamIndex: Preferred subtitle stream index
    /// - Returns: Playback session info with available media sources
    func getPlaybackInfo(
        itemId: String,
        startTimeTicks: Int64?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws -> PlaybackSessionInfo

    /// Resolve the stream URL and play method for a media source: the
    /// original file when the source (and requested tracks) allow direct
    /// play, the HLS universal endpoint otherwise
    /// - Parameters:
    ///   - source: The media source chosen from PlaybackInfo
    ///   - parameters: Item and stream selection parameters
    ///   - assumeInterposer: Whether the loopback server will carry this
    ///     session's playlists (the normal case); pass false only on the
    ///     degraded path after the listener failed to start, which restores
    ///     the app-owned TS/H.264 subtitle delivery
    /// - Returns: The stream URL paired with the play method to report
    /// - Throws: `APIError.notAuthenticated` if there is no access token
    func resolveStream(
        for source: MediaSource,
        parameters: StreamParameters,
        assumeInterposer: Bool,
    ) throws -> StreamResolution

    /// Report that playback has started
    func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        playMethod: PlayMethod,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws

    /// Report playback progress, including the current track selection so
    /// in-place subtitle switches (no new start report) stay visible server-side
    func reportPlaybackProgress(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        playMethod: PlayMethod,
        isPaused: Bool,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws

    /// Report that playback has stopped
    func reportPlaybackStopped(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
    ) async throws

    // MARK: - Playback Extras

    /// Fetch the ancillary playback data for an item: the trickplay
    /// (seek preview) manifest and chapters
    ///
    /// Both live on the item DTO, not in PlaybackInfo, so this is a single
    /// fields-scoped item fetch shared by everything playback resolves up
    /// front.
    /// - Parameter itemId: The item ID
    /// - Returns: The extras; trickplay is nil and chapters empty when the
    ///   server has no data
    func getPlaybackExtras(itemId: String) async throws -> PlaybackExtras

    /// Build the URL for one chapter image
    /// (`/Items/{itemId}/Images/Chapter/{chapterIndex}`)
    /// - Parameters:
    ///   - itemId: The item the chapter belongs to
    ///   - chapterIndex: The chapter's position in the server's chapter
    ///     array (`Chapter.imageIndex`)
    ///   - tag: The chapter's image tag (`Chapter.imageTag`)
    ///   - maxWidth: Optional maximum width in pixels
    /// - Returns: The chapter image URL
    func chapterImageURL(itemId: String, chapterIndex: Int, tag: String, maxWidth: Int?) -> URL

    /// Build the authenticated URL for one trickplay tile sheet
    /// (`/Videos/{itemId}/Trickplay/{width}/{index}.jpg`)
    ///
    /// Called per scrub movement, so it returns nil instead of throwing
    /// when there is no access token.
    /// - Parameters:
    ///   - itemId: The item the trickplay data belongs to
    ///   - width: The resolution key (`TrickplayInfo.widthKey`)
    ///   - tileIndex: The tile sheet index (`TrickplayTileLocation.tileIndex`)
    ///   - mediaSourceId: The media source the manifest entry is keyed by
    /// - Returns: The tile sheet URL, or nil when not authenticated
    func trickplayTileURL(itemId: String, width: Int, tileIndex: Int, mediaSourceId: String?) -> URL?

    // MARK: - Episodes

    /// Fetch the episode immediately following the given episode
    /// - Parameter episode: The current episode
    /// - Returns: The next episode, or nil if this is the last one (or not an episode)
    func getNextEpisode(after episode: MediaItem) async throws -> MediaItem?

    /// Fetch a series' seasons, in order (Specials come back as season 0)
    func getSeasons(seriesId: String) async throws -> [MediaItem]

    /// Fetch a series' episodes in series order, with user data (watched
    /// state, progress) for the current user. Pass a season id to limit the
    /// fetch to one season; nil returns every episode of the series.
    func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem]

    /// The episode the user should watch next for a series: the in-progress or
    /// first-unwatched episode per the server's Next Up logic, or nil when the
    /// server has no suggestion (e.g., fully watched, or never started —
    /// callers can fall back to the first episode)
    func getNextUpEpisode(seriesId: String) async throws -> MediaItem?

    /// The user's cross-series Next Up queue: the next episode to watch for
    /// each in-progress series, per the server's Next Up logic. Excludes
    /// never-started series and resumable episodes (those belong to Continue
    /// Watching).
    /// - Parameter limit: Maximum number of episodes to return
    func getNextUpItems(limit: Int?) async throws -> [MediaItem]

    /// The user's most recently played episodes across all libraries, newest
    /// first — the recency signal for ordering Next Up entries by when their
    /// series was last watched (a next-up episode is unwatched, so it carries
    /// no `lastPlayedDate` of its own).
    /// - Parameter limit: Maximum number of episodes to return
    func getRecentlyPlayedEpisodes(limit: Int?) async throws -> [MediaItem]

    // MARK: - User Data

    /// Mark an item as played for the current user
    func markPlayed(itemId: String) async throws

    /// Mark an item as unplayed for the current user
    func markUnplayed(itemId: String) async throws

    /// Add an item to the current user's favorites
    func markFavorite(itemId: String) async throws

    /// Remove an item from the current user's favorites
    func unmarkFavorite(itemId: String) async throws
}

public extension JellyfinClientProtocol {
    /// The normal path: assume the loopback interposer carries the session
    func resolveStream(for source: MediaSource, parameters: StreamParameters) throws -> StreamResolution {
        try resolveStream(for: source, parameters: parameters, assumeInterposer: true)
    }

    /// Tear down the server-side transcode for a play session. Default
    /// no-op so conformances that never transcode need not care; the real
    /// client sends `DELETE /Videos/ActiveEncodings`.
    func stopEncoding(playSessionId _: String) async {}
}

/// Image types available from Jellyfin
public enum ImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case banner = "Banner"
    case thumb = "Thumb"
    case logo = "Logo"
    case art = "Art"
    case screenshot = "Screenshot"
    case chapter = "Chapter"
}

// MARK: - Configuration

/// Configuration for creating a JellyfinClient
public struct JellyfinClientConfiguration: Sendable {
    /// The server URL
    public let serverURL: URL

    /// Client name reported to the server
    public let clientName: String

    /// Client version reported to the server
    public let clientVersion: String

    /// Device name reported to the server
    public let deviceName: String

    /// Unique device identifier
    public let deviceID: String

    public init(
        serverURL: URL,
        clientName: String = "Jelly Shark",
        clientVersion: String = "0.0.1",
        deviceName: String = "Apple TV",
        deviceID: String = UUID().uuidString,
    ) {
        self.serverURL = serverURL
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

// MARK: - Default Implementation

/// Default Jellyfin client implementation that wraps the official SDK
///
/// This class provides a clean, app-focused API while leveraging the official
/// Jellyfin SDK (jellyfin-sdk-swift) for all network operations. The SDK handles:
/// - Authentication and session management
/// - Automatic authorization header injection
/// - Date encoding/decoding
/// - Type-safe API requests
///
/// Our wrapper adds:
/// - Clean, domain-specific types (User, MediaItem, Library)
/// - Simplified API surface for common operations
/// - Error translation to app-specific error types
public final class JellyfinClient: JellyfinClientProtocol, @unchecked Sendable {
    // MARK: - Properties

    public let serverURL: URL

    /// The client configuration (kept for device identity in stream URLs)
    private let configuration: JellyfinClientConfiguration

    /// The underlying SDK client
    private let sdkClient: JellyfinAPI.JellyfinClient

    /// Cached current user
    private var _currentUser: User?

    /// Cached user ID for API calls
    private var _userId: String?

    /// Cached access token for URLs that authenticate via query parameter
    private var _accessToken: String?

    public var currentUser: User? {
        _currentUser
    }

    public var isAuthenticated: Bool {
        _currentUser != nil
    }

    public var accessToken: String? {
        _accessToken
    }

    // MARK: - Initialization

    /// Create a new JellyfinClient, optionally restoring a previously saved session
    ///
    /// When a saved token and user ID are provided the client can make
    /// authenticated requests immediately, but `isAuthenticated` stays false
    /// until `fetchCurrentUser()` validates the token against the server.
    /// - Parameters:
    ///   - configuration: The client configuration
    ///   - accessToken: A saved access token to restore, if any
    ///   - userID: The saved user ID belonging to the token, if any
    public init(
        configuration: JellyfinClientConfiguration,
        accessToken: String? = nil,
        userID: String? = nil,
    ) {
        self.serverURL = configuration.serverURL
        self.configuration = configuration

        let sdkConfiguration = JellyfinAPI.JellyfinClient.Configuration(
            url: configuration.serverURL,
            accessToken: accessToken,
            client: configuration.clientName,
            deviceName: configuration.deviceName,
            deviceID: configuration.deviceID,
            version: configuration.clientVersion,
        )

        self.sdkClient = JellyfinAPI.JellyfinClient(configuration: sdkConfiguration)
        self._accessToken = accessToken
        self._userId = userID
    }

    // MARK: - Authentication

    public func authenticate(username: String, password: String) async throws -> User {
        do {
            let response = try await sdkClient.signIn(username: username, password: password)

            guard let userDto = response.user else {
                throw APIError.unauthorized
            }

            let user = User(from: userDto)
            _currentUser = user
            _userId = userDto.id
            _accessToken = response.accessToken

            return user
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func signOut() async {
        try? await sdkClient.signOut()
        _currentUser = nil
        _userId = nil
        _accessToken = nil
    }

    public func fetchCurrentUser() async throws -> User {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let response = try await sdkClient.send(Paths.getUserByID(userID: userId))

            let user = User(from: response.value)
            _currentUser = user

            return user
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    /// Map SDK/transport errors to APIError, surfacing HTTP status codes
    private static func mapTransportError(_ error: Error) -> APIError {
        if let apiError = error as? Get.APIError,
           case let .unacceptableStatusCode(statusCode) = apiError
        {
            switch statusCode {
            case 401:
                return .unauthorized
            case 403:
                return .forbidden
            case 404:
                return .notFound
            case 500...:
                return .serverError(statusCode: statusCode)
            default:
                return .httpError(statusCode: statusCode)
            }
        }

        return .networkError(error.localizedDescription)
    }

    // MARK: - Libraries

    public func getLibraries() async throws -> [Library] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetUserViewsParameters()
            parameters.userID = userId

            let response = try await sdkClient.send(
                Paths.getUserViews(parameters: parameters),
            )

            return response.value.items?.compactMap { Library(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getLibraryItems(
        libraryId: String,
        itemTypes: [MediaType]?,
        query: LibraryQuery,
        limit: Int,
        startIndex: Int,
    ) async throws -> MediaItemPage {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetItemsParameters()
            parameters.userID = userId
            parameters.parentID = libraryId
            parameters.limit = limit
            parameters.startIndex = startIndex
            parameters.isRecursive = true
            // Recursive fetches return a library's entire tree (a TV library
            // yields series + seasons + episodes); the type filter keeps the
            // grid to top-level titles.
            parameters.includeItemTypes = itemTypes.map { $0.compactMap(\.baseItemKind) }
            parameters.fields = [.overview, .genres, .dateCreated, .mediaSources]
            parameters.sortBy = query.sort.sdkSortBy
            parameters.sortOrder = [query.direction.sdkSortOrder]
            parameters.enableTotalRecordCount = true
            Self.apply(query, to: &parameters)

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            let value = response.value
            return MediaItemPage(
                items: value.items?.compactMap { MediaItem(from: $0) } ?? [],
                startIndex: value.startIndex ?? startIndex,
                totalRecordCount: value.totalRecordCount,
            )
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    /// Translate a query's filter selections onto an items request
    private static func apply(_ query: LibraryQuery, to parameters: inout Paths.GetItemsParameters) {
        parameters.genres = query.genres.isEmpty ? nil : query.genres.sorted()
        parameters.years = query.expandedYears
        parameters.officialRatings = query.officialRatings.isEmpty ? nil : query.officialRatings.sorted()
        parameters.filters = query.sdkFilters
    }

    /// Largest result set the narrowing scan will fetch in one request;
    /// beyond this the scan reports nil and menus fall back to full options
    private static let narrowingScanLimit = 2000

    public func getLibraryFilterOptions(
        libraryId: String,
        itemTypes: [MediaType]?,
        matching query: LibraryQuery,
    ) async throws -> LibraryFilterOptions? {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetItemsParameters()
            parameters.userID = userId
            parameters.parentID = libraryId
            parameters.isRecursive = true
            parameters.includeItemTypes = itemTypes.map { $0.compactMap(\.baseItemKind) }
            // A slim scan: just enough of each matching item to aggregate
            // the filter values still in play
            parameters.fields = [.genres]
            parameters.enableImages = false
            parameters.enableUserData = false
            parameters.limit = Self.narrowingScanLimit
            parameters.enableTotalRecordCount = true
            Self.apply(query, to: &parameters)

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            let value = response.value
            let items = value.items ?? []
            if let total = value.totalRecordCount, total > items.count {
                return nil
            }
            return LibraryFilterOptions(aggregating: items)
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getLibraryFilterOptions(
        libraryId: String,
        itemTypes: [MediaType]?,
    ) async throws -> LibraryFilterOptions {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let parameters = Paths.GetQueryFiltersLegacyParameters(
                userID: userId,
                parentID: libraryId,
                includeItemTypes: itemTypes.map { $0.compactMap(\.baseItemKind) },
            )

            let response = try await sdkClient.send(
                Paths.getQueryFiltersLegacy(parameters: parameters),
            )

            let value = response.value
            return LibraryFilterOptions(
                genres: value.genres ?? [],
                officialRatings: value.officialRatings ?? [],
                years: value.years ?? [],
            )
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - Media

    public func getCollectionItems(collectionId: String) async throws -> [MediaItem] {
        // A BoxSet's id is a valid `parentId`, so its children come from the
        // same paged items endpoint as library grids. Collections are small
        // (a franchise, not a library), so one generously-sized page is
        // plenty — pagination would be over-engineering here.
        try await getLibraryItems(
            libraryId: collectionId,
            itemTypes: nil,
            query: LibraryQuery(sort: .releaseDate, direction: .ascending),
            limit: 200,
            startIndex: 0,
        ).items
    }

    public func getMediaItem(itemId: String) async throws -> MediaItem {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let response = try await sdkClient.send(
                Paths.getItem(itemID: itemId, userID: userId),
            )

            return MediaItem(from: response.value)
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getSimilarItems(itemId: String, limit: Int? = 12) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetSimilarItemsParameters()
            parameters.userID = userId
            parameters.limit = limit
            parameters.fields = [.overview, .genres, .dateCreated]

            let response = try await sdkClient.send(
                Paths.getSimilarItems(itemID: itemId, parameters: parameters),
            )

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func searchItems(query: String, limit: Int? = 40) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetItemsParameters()
            parameters.userID = userId
            parameters.searchTerm = query
            parameters.limit = limit
            parameters.isRecursive = true
            parameters.includeItemTypes = [.movie, .series, .episode]
            parameters.fields = [.overview, .genres, .dateCreated]
            parameters.sortBy = [.sortName]
            parameters.sortOrder = [JellyfinAPI.SortOrder.ascending]

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - People

    public func getPerson(personId: String) async throws -> Person {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let response = try await sdkClient.send(
                Paths.getItem(itemID: personId, userID: userId),
            )

            return Person(from: response.value)
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getItemsFeaturingPerson(
        personId: String,
        itemTypes: [MediaType],
        personTypes: [String]?,
        limit: Int?,
    ) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetItemsParameters()
            parameters.userID = userId
            parameters.limit = limit
            parameters.isRecursive = true
            parameters.personIDs = [personId]
            parameters.personTypes = personTypes
            parameters.includeItemTypes = itemTypes.compactMap(\.baseItemKind)
            parameters.fields = [.overview, .genres, .dateCreated]
            // Newest work first: recency is the natural read of a filmography.
            parameters.sortBy = [.premiereDate, .productionYear, .sortName]
            parameters.sortOrder = [JellyfinAPI.SortOrder.descending]

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getImageURL(itemId: String, imageType: ImageType, maxWidth: Int? = nil, maxHeight: Int? = nil) -> URL {
        // Append to the server URL rather than overwriting the path,
        // so servers hosted under a path prefix (e.g. /jellyfin) keep working
        let endpoint = serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Images")
            .appendingPathComponent(imageType.rawValue)

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return serverURL
        }

        var queryItems: [URLQueryItem] = []
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let maxHeight {
            queryItems.append(URLQueryItem(name: "maxHeight", value: String(maxHeight)))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        return components.url ?? serverURL
    }

    // MARK: - Resume

    public func getResumeItems(limit: Int? = 10) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetResumeItemsParameters()
            parameters.userID = userId
            parameters.limit = limit
            parameters.fields = [.overview, .genres, .dateCreated]
            parameters.mediaTypes = [.video]

            let response = try await sdkClient.send(
                Paths.getResumeItems(parameters: parameters),
            )

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - Latest

    public func getLatestItems(libraryId: String? = nil, limit: Int? = 16) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetLatestMediaParameters()
            parameters.userID = userId
            parameters.parentID = libraryId
            parameters.limit = limit
            parameters.fields = [.overview, .genres, .dateCreated]

            let response = try await sdkClient.send(
                Paths.getLatestMedia(parameters: parameters),
            )

            return response.value.compactMap { MediaItem(from: $0) }
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - Playback

    public func getPlaybackInfo(
        itemId: String,
        startTimeTicks: Int64?,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
    ) async throws -> PlaybackSessionInfo {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let body = JellyfinAPI.PlaybackInfoDto(
                audioStreamIndex: audioStreamIndex,
                isAutoOpenLiveStream: true,
                deviceProfile: Self.deviceProfile,
                enableDirectPlay: true,
                enableDirectStream: true,
                enableTranscoding: true,
                // Without an explicit budget the server applies a low default
                // bitrate cap and refuses direct play for most real files
                // (observed: ~2.5 Mbps cutoff). Apple TV is a wired/strong-
                // wifi LAN device; declare a generous ceiling.
                maxStreamingBitrate: Self.maxStreamingBitrate,
                startTimeTicks: startTimeTicks.map(Int.init),
                subtitleStreamIndex: subtitleStreamIndex,
                userID: userId,
            )

            let response = try await sdkClient.send(
                Paths.getPostedPlaybackInfo(itemID: itemId, body),
            )

            if let errorCode = response.value.errorCode {
                throw APIError.generic("Playback not possible: \(errorCode.rawValue)")
            }

            let sessionInfo = PlaybackSessionInfo(from: response.value)

            guard !sessionInfo.mediaSources.isEmpty else {
                throw APIError.generic("No playable media sources for this item")
            }

            return sessionInfo
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func resolveStream(
        for source: MediaSource,
        parameters: StreamParameters,
        assumeInterposer: Bool,
    ) throws -> StreamResolution {
        guard let accessToken = _accessToken else {
            throw APIError.notAuthenticated
        }

        let method = source.playMethod(
            audioStreamIndex: parameters.audioStreamIndex,
            subtitleStreamIndex: parameters.subtitleStreamIndex,
        )

        let url: URL? = switch method {
        case .directPlay:
            StreamURLBuilder.directPlayURL(
                serverURL: serverURL,
                accessToken: accessToken,
                deviceId: configuration.deviceID,
                parameters: parameters,
                container: source.container,
                eTag: source.eTag,
            )
        case .directStream, .transcode:
            StreamURLBuilder.hlsURL(
                serverURL: serverURL,
                accessToken: accessToken,
                deviceId: configuration.deviceID,
                parameters: parameters,
                subtitleMethod: source.subtitleRequiresBurnIn(at: parameters.subtitleStreamIndex) ? .encode : .hls,
                assumeInterposer: assumeInterposer,
                sourceVideoCodec: source.videoCodec,
                eTag: source.eTag,
            )
        }

        guard let url else {
            throw APIError.invalidURL
        }

        return StreamResolution(url: url, playMethod: method)
    }

    /// Ask the server to stop the transcode backing a play session. A
    /// rebuild abandons its old PlaySessionId without a stopped report, so
    /// without this the orphaned ffmpeg runs until the server's idle
    /// timeout. Fire-and-forget: failure only delays that cleanup.
    public func stopEncoding(playSessionId: String) async {
        _ = try? await sdkClient.send(Paths.stopEncodingProcess(
            deviceID: configuration.deviceID,
            playSessionID: playSessionId,
        ))
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
        do {
            let info = JellyfinAPI.PlaybackStartInfo(
                audioStreamIndex: audioStreamIndex,
                canSeek: true,
                isPaused: false,
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playMethod: JellyfinAPI.PlayMethod(from: playMethod),
                playSessionID: playSessionId,
                positionTicks: Int(positionTicks),
                subtitleStreamIndex: subtitleStreamIndex,
            )

            _ = try await sdkClient.send(Paths.reportPlaybackStart(info))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
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
        do {
            let info = JellyfinAPI.PlaybackProgressInfo(
                audioStreamIndex: audioStreamIndex,
                canSeek: true,
                isPaused: isPaused,
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playMethod: JellyfinAPI.PlayMethod(from: playMethod),
                playSessionID: playSessionId,
                positionTicks: Int(positionTicks),
                subtitleStreamIndex: subtitleStreamIndex,
            )

            _ = try await sdkClient.send(Paths.reportPlaybackProgress(info))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func reportPlaybackStopped(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
    ) async throws {
        do {
            let info = JellyfinAPI.PlaybackStopInfo(
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playSessionID: playSessionId,
                positionTicks: Int(positionTicks),
            )

            _ = try await sdkClient.send(Paths.reportPlaybackStopped(info))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - Playback Extras

    public func getPlaybackExtras(itemId: String) async throws -> PlaybackExtras {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            // Trickplay, chapters, and people are not part of
            // Paths.getItem's fixed response shape; the ids-filtered items
            // endpoint is the way to request those fields explicitly.
            var parameters = Paths.GetItemsParameters()
            parameters.userID = userId
            parameters.ids = [itemId]
            parameters.fields = [.trickplay, .chapters, .people]

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            guard let dto = response.value.items?.first else {
                return PlaybackExtras()
            }
            return PlaybackExtras(
                trickplay: dto.trickplay.flatMap { TrickplayManifest(from: $0) },
                chapters: Chapter.chapters(from: dto.chapters ?? []),
                people: CastMember.members(from: dto.people ?? []),
            )
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func chapterImageURL(itemId: String, chapterIndex: Int, tag: String, maxWidth: Int?) -> URL {
        let endpoint = serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Images")
            .appendingPathComponent(ImageType.chapter.rawValue)
            .appendingPathComponent(String(chapterIndex))

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }

        var queryItems = [URLQueryItem(name: "tag", value: tag)]
        if let maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        components.queryItems = queryItems
        return components.url ?? endpoint
    }

    public func trickplayTileURL(itemId: String, width: Int, tileIndex: Int, mediaSourceId: String?) -> URL? {
        guard let accessToken = _accessToken else {
            return nil
        }

        return StreamURLBuilder.trickplayTileURL(
            serverURL: serverURL,
            accessToken: accessToken,
            deviceId: configuration.deviceID,
            itemId: itemId,
            width: width,
            tileIndex: tileIndex,
            mediaSourceId: mediaSourceId,
        )
    }

    // MARK: - Episodes

    public func getNextEpisode(after episode: MediaItem) async throws -> MediaItem? {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        guard episode.type == .episode, let seriesId = episode.seriesId else {
            return nil
        }

        do {
            let parameters = Paths.GetEpisodesParameters(
                userID: userId,
                fields: [.overview, .mediaSources],
                startItemID: episode.id,
                limit: 2,
            )

            let response = try await sdkClient.send(
                Paths.getEpisodes(seriesID: seriesId, parameters: parameters),
            )

            let items = response.value.items ?? []

            // The first item is the current episode; the next one follows it
            guard items.count >= 2, items[0].id == episode.id else {
                return nil
            }

            return MediaItem(from: items[1])
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getSeasons(seriesId: String) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetSeasonsParameters()
            parameters.userID = userId

            let response = try await sdkClient.send(
                Paths.getSeasons(seriesID: seriesId, parameters: parameters),
            )

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetEpisodesParameters()
            parameters.userID = userId
            parameters.seasonID = seasonId
            // Overview feeds a future synopsis treatment on the cards; user
            // data (watched/progress) rides along by default.
            parameters.fields = [.overview]

            let response = try await sdkClient.send(
                Paths.getEpisodes(seriesID: seriesId, parameters: parameters),
            )

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getNextUpEpisode(seriesId: String) async throws -> MediaItem? {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetNextUpParameters()
            parameters.userID = userId
            parameters.seriesID = seriesId
            parameters.limit = 1
            // Surface the first episode for never-started series too, so the
            // hero Play button always has a target.
            parameters.isDisableFirstEpisode = false
            parameters.enableResumable = true

            let response = try await sdkClient.send(
                Paths.getNextUp(parameters: parameters),
            )

            return response.value.items?.first.map { MediaItem(from: $0) }
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getNextUpItems(limit: Int?) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetNextUpParameters()
            parameters.userID = userId
            parameters.limit = limit
            // Unlike the per-series variant: skip never-started series (their
            // first episodes aren't "next up" for a Home shelf) and exclude
            // resumable episodes (those already surface in Continue Watching).
            parameters.isDisableFirstEpisode = true
            parameters.enableResumable = false
            // `dateCreated` lets the merged Continue Watching lane rank a
            // just-added episode of an actively watched show by its arrival.
            parameters.fields = [.overview, .dateCreated]

            let response = try await sdkClient.send(
                Paths.getNextUp(parameters: parameters),
            )

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getRecentlyPlayedEpisodes(limit: Int?) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetItemsParameters()
            parameters.userID = userId
            parameters.limit = limit
            parameters.isRecursive = true
            parameters.includeItemTypes = [.episode]
            parameters.filters = [.isPlayed]
            parameters.sortBy = [.datePlayed]
            parameters.sortOrder = [JellyfinAPI.SortOrder.descending]

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - User Data

    public func markPlayed(itemId: String) async throws {
        do {
            _ = try await sdkClient.send(Paths.markPlayedItem(itemID: itemId, userID: _userId))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func markUnplayed(itemId: String) async throws {
        do {
            _ = try await sdkClient.send(Paths.markUnplayedItem(itemID: itemId, userID: _userId))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func markFavorite(itemId: String) async throws {
        do {
            _ = try await sdkClient.send(Paths.markFavoriteItem(itemID: itemId, userID: _userId))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func unmarkFavorite(itemId: String) async throws {
        do {
            _ = try await sdkClient.send(Paths.unmarkFavoriteItem(itemID: itemId, userID: _userId))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }
}

// MARK: - Convenience Extensions

public extension JellyfinClientProtocol {
    /// Get the image URL with default parameters
    func getImageURL(itemId: String, imageType: ImageType) -> URL {
        getImageURL(itemId: itemId, imageType: imageType, maxWidth: nil, maxHeight: nil)
    }

    /// Get the URL for a user's profile image: `/Users/{userId}/Images/Primary`
    /// - Parameters:
    ///   - userId: The user ID
    ///   - maxWidth: Optional maximum width for the image
    /// - Returns: The user image URL
    func getUserImageURL(userId: String, maxWidth: Int? = nil) -> URL {
        let endpoint = serverURL
            .appendingPathComponent("Users")
            .appendingPathComponent(userId)
            .appendingPathComponent("Images")
            .appendingPathComponent("Primary")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return serverURL
        }

        if let maxWidth {
            components.queryItems = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
        }

        return components.url ?? serverURL
    }
}

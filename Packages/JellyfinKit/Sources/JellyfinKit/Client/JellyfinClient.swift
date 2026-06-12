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

    /// Fetch items from a library
    /// - Parameters:
    ///   - libraryId: The library ID
    ///   - limit: Maximum number of items to return
    ///   - startIndex: Starting index for pagination
    /// - Returns: Array of media items
    func getLibraryItems(libraryId: String, limit: Int?, startIndex: Int?) async throws -> [MediaItem]

    // MARK: - Media

    /// Fetch details for a specific media item
    /// - Parameter itemId: The item ID
    /// - Returns: The media item details
    func getMediaItem(itemId: String) async throws -> MediaItem

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
        subtitleStreamIndex: Int?
    ) async throws -> PlaybackSessionInfo

    /// Build an HLS stream URL for an item
    /// - Parameter parameters: Item and stream selection parameters
    /// - Returns: The stream URL
    /// - Throws: `APIError.notAuthenticated` if there is no access token
    func hlsStreamURL(parameters: StreamParameters, eTag: String?) throws -> URL

    /// Report that playback has started
    func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws

    /// Report playback progress
    func reportPlaybackProgress(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        isPaused: Bool
    ) async throws

    /// Report that playback has stopped
    func reportPlaybackStopped(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64
    ) async throws

    // MARK: - Episodes

    /// Fetch the episode immediately following the given episode
    /// - Parameter episode: The current episode
    /// - Returns: The next episode, or nil if this is the last one (or not an episode)
    func getNextEpisode(after episode: MediaItem) async throws -> MediaItem?
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
        deviceID: String = UUID().uuidString
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

    public var currentUser: User? { _currentUser }
    public var isAuthenticated: Bool { _currentUser != nil }
    public var accessToken: String? { _accessToken }

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
        userID: String? = nil
    ) {
        self.serverURL = configuration.serverURL
        self.configuration = configuration

        let sdkConfiguration = JellyfinAPI.JellyfinClient.Configuration(
            url: configuration.serverURL,
            accessToken: accessToken,
            client: configuration.clientName,
            deviceName: configuration.deviceName,
            deviceID: configuration.deviceID,
            version: configuration.clientVersion
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
           case .unacceptableStatusCode(let statusCode) = apiError {
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
                Paths.getUserViews(parameters: parameters)
            )

            return response.value.items?.compactMap { Library(from: $0) } ?? []
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getLibraryItems(libraryId: String, limit: Int?, startIndex: Int?) async throws -> [MediaItem] {
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
            parameters.fields = [.overview, .genres, .dateCreated, .mediaSources]
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

    // MARK: - Media

    public func getMediaItem(itemId: String) async throws -> MediaItem {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let response = try await sdkClient.send(
                Paths.getItem(itemID: itemId, userID: userId)
            )

            return MediaItem(from: response.value)
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    public func getImageURL(itemId: String, imageType: ImageType, maxWidth: Int? = nil, maxHeight: Int? = nil) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = "/Items/\(itemId)/Images/\(imageType.rawValue)"

        var queryItems: [URLQueryItem] = []
        if let maxWidth = maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let maxHeight = maxHeight {
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
                Paths.getResumeItems(parameters: parameters)
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
                Paths.getLatestMedia(parameters: parameters)
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
        subtitleStreamIndex: Int?
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
                startTimeTicks: startTimeTicks.map(Int.init),
                subtitleStreamIndex: subtitleStreamIndex,
                userID: userId
            )

            let response = try await sdkClient.send(
                Paths.getPostedPlaybackInfo(itemID: itemId, body)
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

    public func hlsStreamURL(parameters: StreamParameters, eTag: String?) throws -> URL {
        guard let accessToken = _accessToken else {
            throw APIError.notAuthenticated
        }

        guard let url = StreamURLBuilder.hlsURL(
            serverURL: serverURL,
            accessToken: accessToken,
            deviceId: configuration.deviceID,
            parameters: parameters,
            eTag: eTag
        ) else {
            throw APIError.invalidURL
        }

        return url
    }

    public func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String?,
        playSessionId: String?,
        positionTicks: Int64,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?
    ) async throws {
        do {
            let info = JellyfinAPI.PlaybackStartInfo(
                audioStreamIndex: audioStreamIndex,
                canSeek: true,
                isPaused: false,
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playMethod: .transcode,
                playSessionID: playSessionId,
                positionTicks: Int(positionTicks),
                subtitleStreamIndex: subtitleStreamIndex
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
        isPaused: Bool
    ) async throws {
        do {
            let info = JellyfinAPI.PlaybackProgressInfo(
                canSeek: true,
                isPaused: isPaused,
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playMethod: .transcode,
                playSessionID: playSessionId,
                positionTicks: Int(positionTicks)
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
        positionTicks: Int64
    ) async throws {
        do {
            let info = JellyfinAPI.PlaybackStopInfo(
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playSessionID: playSessionId,
                positionTicks: Int(positionTicks)
            )

            _ = try await sdkClient.send(Paths.reportPlaybackStopped(info))
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.mapTransportError(error)
        }
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
                limit: 2
            )

            let response = try await sdkClient.send(
                Paths.getEpisodes(seriesID: seriesId, parameters: parameters)
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
}

// MARK: - Convenience Extensions

public extension JellyfinClientProtocol {
    /// Get the image URL with default parameters
    func getImageURL(itemId: String, imageType: ImageType) -> URL {
        getImageURL(itemId: itemId, imageType: imageType, maxWidth: nil, maxHeight: nil)
    }
}

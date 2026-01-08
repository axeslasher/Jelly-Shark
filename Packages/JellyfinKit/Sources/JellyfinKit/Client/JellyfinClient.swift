import Foundation
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

    // MARK: - Authentication

    /// Authenticate with the Jellyfin server
    /// - Parameters:
    ///   - username: The username
    ///   - password: The password
    /// - Returns: The authenticated user
    func authenticate(username: String, password: String) async throws -> User

    /// Sign out and clear credentials
    func signOut() async

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

    /// The underlying SDK client
    private let sdkClient: JellyfinAPI.JellyfinClient

    /// Cached current user
    private var _currentUser: User?

    /// Cached user ID for API calls
    private var _userId: String?

    public var currentUser: User? { _currentUser }
    public var isAuthenticated: Bool { _currentUser != nil }

    // MARK: - Initialization

    /// Create a new JellyfinClient with the given configuration
    /// - Parameter configuration: The client configuration
    public init(configuration: JellyfinClientConfiguration) {
        self.serverURL = configuration.serverURL

        let sdkConfiguration = JellyfinAPI.JellyfinClient.Configuration(
            url: configuration.serverURL,
            client: configuration.clientName,
            version: configuration.clientVersion,
            deviceName: configuration.deviceName,
            deviceID: configuration.deviceID
        )

        self.sdkClient = JellyfinAPI.JellyfinClient(configuration: sdkConfiguration)
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

            return user
        } catch let error as JellyfinAPI.JellyfinAPIError {
            throw APIError.from(sdkError: error)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    public func signOut() async {
        await sdkClient.signOut()
        _currentUser = nil
        _userId = nil
    }

    // MARK: - Libraries

    public func getLibraries() async throws -> [Library] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let response = try await sdkClient.send(
                Paths.getUserViews(userID: userId)
            )

            return response.value.items?.compactMap { Library(from: $0) } ?? []
        } catch let error as JellyfinAPI.JellyfinAPIError {
            throw APIError.from(sdkError: error)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
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
            parameters.sortBy = [ItemSortBy.sortName.rawValue]
            parameters.sortOrder = [JellyfinAPI.SortOrder.ascending]

            let response = try await sdkClient.send(Paths.getItems(parameters: parameters))

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as JellyfinAPI.JellyfinAPIError {
            throw APIError.from(sdkError: error)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Media

    public func getMediaItem(itemId: String) async throws -> MediaItem {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            let response = try await sdkClient.send(
                Paths.getItem(userID: userId, itemID: itemId)
            )

            return MediaItem(from: response.value)
        } catch let error as JellyfinAPI.JellyfinAPIError {
            throw APIError.from(sdkError: error)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
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
            parameters.limit = limit
            parameters.fields = [.overview, .genres, .dateCreated]
            parameters.mediaTypes = [.video]

            let response = try await sdkClient.send(
                Paths.getResumeItems(userID: userId, parameters: parameters)
            )

            return response.value.items?.compactMap { MediaItem(from: $0) } ?? []
        } catch let error as JellyfinAPI.JellyfinAPIError {
            throw APIError.from(sdkError: error)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Latest

    public func getLatestItems(libraryId: String? = nil, limit: Int? = 16) async throws -> [MediaItem] {
        guard let userId = _userId else {
            throw APIError.notAuthenticated
        }

        do {
            var parameters = Paths.GetLatestMediaParameters()
            parameters.parentID = libraryId
            parameters.limit = limit
            parameters.fields = [.overview, .genres, .dateCreated]

            let response = try await sdkClient.send(
                Paths.getLatestMedia(userID: userId, parameters: parameters)
            )

            return response.value.compactMap { MediaItem(from: $0) }
        } catch let error as JellyfinAPI.JellyfinAPIError {
            throw APIError.from(sdkError: error)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error.localizedDescription)
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

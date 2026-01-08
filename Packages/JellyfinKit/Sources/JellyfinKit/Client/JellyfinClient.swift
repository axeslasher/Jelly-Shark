import Foundation

/// Protocol defining the Jellyfin API client interface
public protocol JellyfinClient: Sendable {
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
    /// - Returns: The image URL
    func getImageURL(itemId: String, imageType: ImageType) -> URL
}

/// Image types available from Jellyfin
public enum ImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case banner = "Banner"
    case thumb = "Thumb"
    case logo = "Logo"
}

// MARK: - Default Implementation

/// Default Jellyfin client implementation
public final class DefaultJellyfinClient: JellyfinClient, @unchecked Sendable {
    public let serverURL: URL

    private var _currentUser: User?
    private var accessToken: String?
    private let urlSession: URLSession

    public var currentUser: User? { _currentUser }
    public var isAuthenticated: Bool { accessToken != nil }

    public init(serverURL: URL, urlSession: URLSession = .shared) {
        self.serverURL = serverURL
        self.urlSession = urlSession
    }

    public func authenticate(username: String, password: String) async throws -> User {
        // TODO: Implement actual authentication
        // POST /Users/authenticatebyname
        throw APIError.notImplemented
    }

    public func signOut() async {
        _currentUser = nil
        accessToken = nil
    }

    public func getLibraries() async throws -> [Library] {
        // TODO: Implement actual API call
        // GET /Users/{userId}/Views
        throw APIError.notImplemented
    }

    public func getLibraryItems(libraryId: String, limit: Int?, startIndex: Int?) async throws -> [MediaItem] {
        // TODO: Implement actual API call
        // GET /Users/{userId}/Items
        throw APIError.notImplemented
    }

    public func getMediaItem(itemId: String) async throws -> MediaItem {
        // TODO: Implement actual API call
        // GET /Items/{itemId}
        throw APIError.notImplemented
    }

    public func getImageURL(itemId: String, imageType: ImageType) -> URL {
        serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemId)
            .appendingPathComponent("Images")
            .appendingPathComponent(imageType.rawValue)
    }
}

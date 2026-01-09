import Foundation

/// Represents a Jellyfin library/collection
///
/// This is a clean, app-specific representation of a library.
/// It is created from the SDK's BaseItemDto via the adapter layer.
public struct Library: Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for the library
    public let id: String

    /// Display name of the library
    public let name: String

    /// Type of content in this library
    public let collectionType: CollectionType?

    /// Tag for the primary image
    public let primaryImageTag: String?

    /// Number of items in the library
    public let childCount: Int?

    public init(
        id: String,
        name: String,
        collectionType: CollectionType? = nil,
        primaryImageTag: String? = nil,
        childCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
        self.primaryImageTag = primaryImageTag
        self.childCount = childCount
    }
}

/// Types of library collections in Jellyfin
public enum CollectionType: String, Sendable, Hashable {
    case movies = "movies"
    case tvshows = "tvshows"
    case music = "music"
    case musicvideos = "musicvideos"
    case homevideos = "homevideos"
    case boxsets = "boxsets"
    case books = "books"
    case photos = "photos"
    case livetv = "livetv"
    case playlists = "playlists"
    case folders = "folders"
    case unknown
}

// MARK: - Computed Properties

extension Library {
    /// SF Symbol name for the library type
    public var systemImageName: String {
        switch collectionType {
        case .movies:
            return "film.fill"
        case .tvshows:
            return "tv.fill"
        case .music:
            return "music.note"
        case .musicvideos:
            return "music.note.tv.fill"
        case .homevideos:
            return "video.fill"
        case .boxsets:
            return "square.stack.fill"
        case .books:
            return "book.fill"
        case .photos:
            return "photo.fill"
        case .livetv:
            return "antenna.radiowaves.left.and.right"
        case .playlists:
            return "music.note.list"
        case .folders:
            return "folder.fill"
        case .unknown, .none:
            return "questionmark.folder.fill"
        }
    }
}

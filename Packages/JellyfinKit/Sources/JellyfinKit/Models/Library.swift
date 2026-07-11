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
        childCount: Int? = nil,
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
    case movies
    case tvshows
    case music
    case musicvideos
    case homevideos
    case boxsets
    case books
    case photos
    case livetv
    case playlists
    case folders
    case unknown
}

public extension CollectionType {
    /// The item types a library grid should show for this collection: the
    /// top-level titles only — a TV library shows series, not the seasons and
    /// episodes a recursive fetch would also return. Nil applies no filter
    /// (mixed/unknown libraries show everything).
    var gridItemTypes: [MediaType]? {
        switch self {
        case .movies: [.movie]
        case .tvshows: [.series]
        case .boxsets: [.boxSet]
        case .music: [.musicAlbum]
        default: nil
        }
    }
}

// MARK: - Computed Properties

public extension Library {
    /// SF Symbol name for the library type
    var systemImageName: String {
        switch collectionType {
        case .movies:
            "film.fill"
        case .tvshows:
            "tv.fill"
        case .music:
            "music.note"
        case .musicvideos:
            "music.note.tv.fill"
        case .homevideos:
            "video.fill"
        case .boxsets:
            "film.stack.fill"
        case .books:
            "book.fill"
        case .photos:
            "photo.fill"
        case .livetv:
            "antenna.radiowaves.left.and.right"
        case .playlists:
            "music.note.list"
        case .folders:
            "folder.fill"
        case .unknown, .none:
            "questionmark.folder.fill"
        }
    }
}

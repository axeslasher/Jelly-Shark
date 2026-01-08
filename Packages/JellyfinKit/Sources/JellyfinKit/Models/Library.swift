import Foundation

/// Represents a Jellyfin library/collection
public struct Library: Identifiable, Sendable, Codable, Equatable {
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
public enum CollectionType: String, Sendable, Codable {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CollectionType(rawValue: rawValue) ?? .unknown
    }
}

// MARK: - Codable

extension Library {
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case primaryImageTag = "PrimaryImageTag"
        case childCount = "ChildCount"
    }
}

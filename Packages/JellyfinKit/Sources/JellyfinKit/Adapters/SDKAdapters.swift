import Foundation
import JellyfinAPI

// MARK: - SDK Type Adapters
//
// This file contains extensions that map Jellyfin SDK types (BaseItemDto, UserDto, etc.)
// to our clean, app-specific types (MediaItem, User, Library).
//
// Benefits of this adapter pattern:
// - Clean API surface for the rest of the app
// - Isolation from SDK changes
// - Only expose fields the app actually needs
// - Add computed properties and conveniences

// MARK: - User Adapter

extension User {
    /// Create a User from the SDK's UserDto
    init(from dto: JellyfinAPI.UserDto) {
        self.init(
            id: dto.id ?? "",
            name: dto.name ?? "Unknown",
            serverId: dto.serverId,
            isAdministrator: dto.policy?.isAdministrator ?? false,
            primaryImageTag: dto.primaryImageTag
        )
    }
}

// MARK: - MediaItem Adapter

extension MediaItem {
    /// Create a MediaItem from the SDK's BaseItemDto
    init(from dto: JellyfinAPI.BaseItemDto) {
        self.init(
            id: dto.id ?? "",
            name: dto.name ?? "Unknown",
            originalTitle: dto.originalTitle,
            type: MediaType(from: dto.type),
            overview: dto.overview,
            productionYear: dto.productionYear,
            runTimeTicks: dto.runTimeTicks,
            communityRating: dto.communityRating,
            officialRating: dto.officialRating,
            genres: dto.genres,
            imageTags: ImageTags(from: dto.imageTags),
            userData: dto.userData.map { UserData(from: $0) },
            seriesId: dto.seriesId,
            seriesName: dto.seriesName,
            seasonId: dto.seasonId,
            seasonName: dto.seasonName,
            indexNumber: dto.indexNumber,
            parentIndexNumber: dto.parentIndexNumber
        )
    }
}

// MARK: - MediaType Adapter

extension MediaType {
    /// Create a MediaType from the SDK's BaseItemKind
    init(from kind: JellyfinAPI.BaseItemKind?) {
        guard let kind = kind else {
            self = .unknown
            return
        }

        switch kind {
        case .movie:
            self = .movie
        case .series:
            self = .series
        case .season:
            self = .season
        case .episode:
            self = .episode
        case .boxSet:
            self = .boxSet
        case .musicAlbum:
            self = .musicAlbum
        case .musicArtist:
            self = .musicArtist
        case .audio:
            self = .audio
        case .video:
            self = .video
        case .folder:
            self = .folder
        case .collectionFolder:
            self = .collectionFolder
        default:
            self = .unknown
        }
    }
}

// MARK: - ImageTags Adapter

extension ImageTags {
    /// Create ImageTags from the SDK's image tags dictionary
    init?(from tags: [String: String]?) {
        guard let tags = tags else { return nil }

        self.init(
            primary: tags["Primary"],
            backdrop: tags["Backdrop"],
            banner: tags["Banner"],
            thumb: tags["Thumb"],
            logo: tags["Logo"]
        )
    }
}

// MARK: - UserData Adapter

extension UserData {
    /// Create UserData from the SDK's UserItemDataDto
    init(from dto: JellyfinAPI.UserItemDataDto) {
        self.init(
            playbackPositionTicks: dto.playbackPositionTicks,
            playCount: dto.playCount,
            isFavorite: dto.isFavorite ?? false,
            played: dto.played ?? false,
            lastPlayedDate: dto.lastPlayedDate
        )
    }
}

// MARK: - Library Adapter

extension Library {
    /// Create a Library from the SDK's BaseItemDto
    init(from dto: JellyfinAPI.BaseItemDto) {
        self.init(
            id: dto.id ?? "",
            name: dto.name ?? "Unknown",
            collectionType: CollectionType(from: dto.collectionType),
            primaryImageTag: dto.imageTags?["Primary"],
            childCount: dto.childCount
        )
    }
}

// MARK: - CollectionType Adapter

extension CollectionType {
    /// Create a CollectionType from the SDK's CollectionTypeOptions
    init(from type: JellyfinAPI.CollectionTypeOptions?) {
        guard let type = type else {
            self = .unknown
            return
        }

        switch type {
        case .movies:
            self = .movies
        case .tvshows:
            self = .tvshows
        case .music:
            self = .music
        case .musicvideos:
            self = .musicvideos
        case .homevideos:
            self = .homevideos
        case .boxsets:
            self = .boxsets
        case .books:
            self = .books
        case .photos:
            self = .photos
        case .livetv:
            self = .livetv
        case .playlists:
            self = .playlists
        case .folders:
            self = .folders
        default:
            self = .unknown
        }
    }
}

// MARK: - APIError Adapter

extension APIError {
    /// Create an APIError from the SDK's JellyfinAPIError
    static func from(sdkError: JellyfinAPI.JellyfinAPIError) -> APIError {
        switch sdkError {
        case .unauthenticated:
            return .unauthorized
        default:
            return .generic(sdkError.localizedDescription)
        }
    }
}

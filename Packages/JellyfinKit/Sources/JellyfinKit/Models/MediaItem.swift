import Foundation

/// Represents a media item from Jellyfin (movie, episode, etc.)
public struct MediaItem: Identifiable, Sendable, Codable, Equatable {
    /// Unique identifier for the item
    public let id: String

    /// Display name of the item
    public let name: String

    /// Original title (if different from name)
    public let originalTitle: String?

    /// Type of media item
    public let type: MediaType

    /// Overview/description of the item
    public let overview: String?

    /// Production year
    public let productionYear: Int?

    /// Runtime in ticks (1 tick = 100 nanoseconds)
    public let runTimeTicks: Int64?

    /// Community rating (e.g., from TMDb)
    public let communityRating: Double?

    /// Official rating (e.g., PG-13, R)
    public let officialRating: String?

    /// Genres associated with this item
    public let genres: [String]?

    /// Tag for the primary image
    public let imageTags: ImageTags?

    /// User-specific data (watch status, favorite, etc.)
    public let userData: UserData?

    /// Series information (for episodes)
    public let seriesId: String?
    public let seriesName: String?
    public let seasonId: String?
    public let seasonName: String?
    public let indexNumber: Int?       // Episode number
    public let parentIndexNumber: Int? // Season number

    public init(
        id: String,
        name: String,
        originalTitle: String? = nil,
        type: MediaType,
        overview: String? = nil,
        productionYear: Int? = nil,
        runTimeTicks: Int64? = nil,
        communityRating: Double? = nil,
        officialRating: String? = nil,
        genres: [String]? = nil,
        imageTags: ImageTags? = nil,
        userData: UserData? = nil,
        seriesId: String? = nil,
        seriesName: String? = nil,
        seasonId: String? = nil,
        seasonName: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.originalTitle = originalTitle
        self.type = type
        self.overview = overview
        self.productionYear = productionYear
        self.runTimeTicks = runTimeTicks
        self.communityRating = communityRating
        self.officialRating = officialRating
        self.genres = genres
        self.imageTags = imageTags
        self.userData = userData
        self.seriesId = seriesId
        self.seriesName = seriesName
        self.seasonId = seasonId
        self.seasonName = seasonName
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
    }
}

// MARK: - Supporting Types

/// Types of media items in Jellyfin
public enum MediaType: String, Sendable, Codable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case audio = "Audio"
    case video = "Video"
    case folder = "Folder"
    case collectionFolder = "CollectionFolder"
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MediaType(rawValue: rawValue) ?? .unknown
    }
}

/// Image tags for a media item
public struct ImageTags: Sendable, Codable, Equatable {
    public let primary: String?
    public let backdrop: String?
    public let banner: String?
    public let thumb: String?
    public let logo: String?

    public init(
        primary: String? = nil,
        backdrop: String? = nil,
        banner: String? = nil,
        thumb: String? = nil,
        logo: String? = nil
    ) {
        self.primary = primary
        self.backdrop = backdrop
        self.banner = banner
        self.thumb = thumb
        self.logo = logo
    }

    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case backdrop = "Backdrop"
        case banner = "Banner"
        case thumb = "Thumb"
        case logo = "Logo"
    }
}

/// User-specific data for a media item
public struct UserData: Sendable, Codable, Equatable {
    /// Playback position in ticks
    public let playbackPositionTicks: Int64?

    /// Number of times played
    public let playCount: Int?

    /// Whether the item is marked as favorite
    public let isFavorite: Bool

    /// Whether the item has been played
    public let played: Bool

    /// Last played date
    public let lastPlayedDate: Date?

    public init(
        playbackPositionTicks: Int64? = nil,
        playCount: Int? = nil,
        isFavorite: Bool = false,
        played: Bool = false,
        lastPlayedDate: Date? = nil
    ) {
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.played = played
        self.lastPlayedDate = lastPlayedDate
    }

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case lastPlayedDate = "LastPlayedDate"
    }
}

// MARK: - Computed Properties

extension MediaItem {
    /// Runtime formatted as hours and minutes
    public var formattedRuntime: String? {
        guard let ticks = runTimeTicks else { return nil }
        let totalMinutes = Int(ticks / 10_000_000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Progress percentage (0.0 - 1.0)
    public var progressPercentage: Double? {
        guard let position = userData?.playbackPositionTicks,
              let total = runTimeTicks,
              total > 0 else { return nil }
        return Double(position) / Double(total)
    }
}

// MARK: - Codable

extension MediaItem {
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case genres = "Genres"
        case imageTags = "ImageTags"
        case userData = "UserData"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonId = "SeasonId"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
    }
}

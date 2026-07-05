import Foundation

/// Represents a media item from Jellyfin (movie, episode, etc.)
///
/// This is a clean, app-specific representation of media.
/// It is created from the SDK's BaseItemDto via the adapter layer.
public struct MediaItem: Identifiable, Sendable, Equatable, Hashable {
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

    /// Critic rating on a 0–100 scale (e.g., Rotten Tomatoes)
    public let criticRating: Double?

    /// Official rating (e.g., PG-13, R)
    public let officialRating: String?

    /// Marketing tagline (movies). Often absent for episodes.
    public let tagline: String?

    /// Genres associated with this item
    public let genres: [String]?

    /// Studios / networks credited on this item
    public let studios: [String]?

    /// First air / theatrical release date
    public let premiereDate: Date?

    /// Date the series ended (series only, when ended)
    public let endDate: Date?

    /// Airing status for series (e.g., "Continuing", "Ended")
    public let status: String?

    /// Direct children count (seasons for a series, episodes for a season)
    public let childCount: Int?

    /// Recursive children count (episodes for a series)
    public let recursiveItemCount: Int?

    /// Display-ready technical facts distilled from the item's media streams
    /// (populated on detail fetches)
    public let technicalInfo: MediaTechnicalInfo?

    /// Tags for various images
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

    /// Cast and crew credited on this item (populated on detail fetches)
    public let people: [CastMember]?

    /// Artwork inherited from ancestors (season/series). Episodes rarely carry
    /// their own backdrops or logos; the server points at the nearest ancestor
    /// that has them.
    public let parentArtwork: ParentArtwork?

    public init(
        id: String,
        name: String,
        originalTitle: String? = nil,
        type: MediaType,
        overview: String? = nil,
        productionYear: Int? = nil,
        runTimeTicks: Int64? = nil,
        communityRating: Double? = nil,
        criticRating: Double? = nil,
        officialRating: String? = nil,
        tagline: String? = nil,
        genres: [String]? = nil,
        studios: [String]? = nil,
        premiereDate: Date? = nil,
        endDate: Date? = nil,
        status: String? = nil,
        childCount: Int? = nil,
        recursiveItemCount: Int? = nil,
        technicalInfo: MediaTechnicalInfo? = nil,
        imageTags: ImageTags? = nil,
        userData: UserData? = nil,
        seriesId: String? = nil,
        seriesName: String? = nil,
        seasonId: String? = nil,
        seasonName: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        people: [CastMember]? = nil,
        parentArtwork: ParentArtwork? = nil
    ) {
        self.id = id
        self.name = name
        self.originalTitle = originalTitle
        self.type = type
        self.overview = overview
        self.productionYear = productionYear
        self.runTimeTicks = runTimeTicks
        self.communityRating = communityRating
        self.criticRating = criticRating
        self.officialRating = officialRating
        self.tagline = tagline
        self.genres = genres
        self.studios = studios
        self.premiereDate = premiereDate
        self.endDate = endDate
        self.status = status
        self.childCount = childCount
        self.recursiveItemCount = recursiveItemCount
        self.technicalInfo = technicalInfo
        self.imageTags = imageTags
        self.userData = userData
        self.seriesId = seriesId
        self.seriesName = seriesName
        self.seasonId = seasonId
        self.seasonName = seasonName
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.people = people
        self.parentArtwork = parentArtwork
    }
}

/// Ancestor-owned artwork an item can inherit when it lacks its own. Each
/// image pairs the tag with the id of the ancestor item that owns it, since
/// image URLs are built against the owning item.
public struct ParentArtwork: Sendable, Equatable, Hashable {
    /// Item owning the nearest ancestor backdrop (usually the series)
    public let backdropItemId: String?
    public let backdropImageTag: String?

    /// Item owning the nearest ancestor logo
    public let logoItemId: String?
    public let logoImageTag: String?

    /// Series primary (poster) tag; its owner is the item's `seriesId`
    public let seriesPrimaryImageTag: String?

    public init(
        backdropItemId: String? = nil,
        backdropImageTag: String? = nil,
        logoItemId: String? = nil,
        logoImageTag: String? = nil,
        seriesPrimaryImageTag: String? = nil
    ) {
        self.backdropItemId = backdropItemId
        self.backdropImageTag = backdropImageTag
        self.logoItemId = logoItemId
        self.logoImageTag = logoImageTag
        self.seriesPrimaryImageTag = seriesPrimaryImageTag
    }
}

// MARK: - Supporting Types

/// Types of media items in Jellyfin
public enum MediaType: String, Sendable, Hashable {
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
}

/// Image tags for a media item
public struct ImageTags: Sendable, Equatable, Hashable {
    public let primary: String?
    public let backdrop: String?
    public let banner: String?
    public let thumb: String?
    public let logo: String?

    /// BlurHash placeholders for the image types the app shows through
    /// `ArtworkImage` (logos and banners get no placeholder treatment).
    public let primaryBlurHash: String?
    public let backdropBlurHash: String?
    public let thumbBlurHash: String?

    public init(
        primary: String? = nil,
        backdrop: String? = nil,
        banner: String? = nil,
        thumb: String? = nil,
        logo: String? = nil,
        primaryBlurHash: String? = nil,
        backdropBlurHash: String? = nil,
        thumbBlurHash: String? = nil
    ) {
        self.primary = primary
        self.backdrop = backdrop
        self.banner = banner
        self.thumb = thumb
        self.logo = logo
        self.primaryBlurHash = primaryBlurHash
        self.backdropBlurHash = backdropBlurHash
        self.thumbBlurHash = thumbBlurHash
    }
}

/// Display-ready technical facts about an item's default media source.
///
/// Deliberately not the raw `MediaStream` list: the adapter reduces the
/// default video/audio/subtitle streams to the handful of labels the UI can
/// badge, keeping the SDK types behind the facade.
public struct MediaTechnicalInfo: Sendable, Equatable, Hashable {
    /// Video resolution class: "8K", "4K", "1080p", "720p", or "SD"
    public let resolution: String?

    /// Dynamic-range label: "Dolby Vision", "HDR10+", "HDR10", "HLG", or
    /// "HDR". `nil` for SDR content — absence is the default, not a badge.
    public let videoRange: String?

    /// Audio format label: "Dolby Atmos", "DTS:X", or a channel layout like
    /// "7.1", "5.1", "Stereo"
    public let audioFormat: String?

    /// Localized display name of the default audio track's language — the
    /// closest proxy the server offers for the title's original audio
    public let originalAudioLanguage: String?

    /// Localized display names of the available audio-track languages, unique,
    /// in stream order
    public let audioLanguages: [String]

    /// Localized display names of the available subtitle languages, unique,
    /// in stream order
    public let subtitleLanguages: [String]

    /// Whether any subtitle track is flagged for the deaf and hard of hearing
    public let hasSDHSubtitles: Bool

    /// Name of the media file on disk (last path component)
    public let fileName: String?

    /// File size in bytes
    public let fileSizeBytes: Int64?

    /// Container format label ("MKV", "MP4")
    public let container: String?

    /// Video codec label ("HEVC", "H.264", "AV1")
    public let videoCodec: String?

    /// Overall bitrate in bits per second
    public let bitrate: Int?

    /// Video frame rate in frames per second (e.g., 23.976)
    public let frameRate: Double?

    public var hasSubtitles: Bool {
        !subtitleLanguages.isEmpty
    }

    public init(
        resolution: String? = nil,
        videoRange: String? = nil,
        audioFormat: String? = nil,
        originalAudioLanguage: String? = nil,
        audioLanguages: [String] = [],
        subtitleLanguages: [String] = [],
        hasSDHSubtitles: Bool = false,
        fileName: String? = nil,
        fileSizeBytes: Int64? = nil,
        container: String? = nil,
        videoCodec: String? = nil,
        bitrate: Int? = nil,
        frameRate: Double? = nil
    ) {
        self.resolution = resolution
        self.videoRange = videoRange
        self.audioFormat = audioFormat
        self.originalAudioLanguage = originalAudioLanguage
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.hasSDHSubtitles = hasSDHSubtitles
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.container = container
        self.videoCodec = videoCodec
        self.bitrate = bitrate
        self.frameRate = frameRate
    }
}

/// User-specific data for a media item
public struct UserData: Sendable, Equatable, Hashable {
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

    /// Whether the user has started watching this item
    public var hasProgress: Bool {
        guard let percentage = progressPercentage else { return false }
        return percentage > 0 && percentage < 1
    }

    /// Year text for display: a plain year for most items, a span for series —
    /// "2008–2013" when ended (single year if it ended the year it started),
    /// "2008–" while continuing.
    public var yearSpanText: String? {
        guard let year = productionYear else { return nil }
        guard type == .series else { return String(year) }

        if status == "Continuing" {
            return "\(year)–"
        }
        let endYear = endDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        if let endYear, endYear != year {
            return "\(year)–\(endYear)"
        }
        return String(year)
    }

    /// BlurHash for a poster slot, mirroring `posterURL`'s primary → thumb
    /// resolution order. (Ancestor-art fallbacks carry no hashes; a nil here
    /// just means the icon placeholder.)
    public var posterBlurHash: String? {
        imageTags?.primaryBlurHash ?? imageTags?.thumbBlurHash
    }

    /// BlurHash for a backdrop slot, mirroring `backdropURL`'s backdrop → thumb
    /// resolution order
    public var backdropBlurHash: String? {
        imageTags?.backdropBlurHash ?? imageTags?.thumbBlurHash
    }

    /// BlurHash for a landscape card, mirroring `landscapeURL`'s thumb →
    /// backdrop → primary resolution order
    public var landscapeBlurHash: String? {
        imageTags?.thumbBlurHash ?? imageTags?.backdropBlurHash ?? imageTags?.primaryBlurHash
    }

    /// Season count for series (e.g., "3 Seasons"); nil for other types
    public var seasonCountText: String? {
        guard type == .series, let count = childCount, count > 0 else { return nil }
        return count == 1 ? "1 Season" : "\(count) Seasons"
    }

    /// Compact season/episode code (e.g., "S2E4"); nil unless the item is an
    /// episode carrying both numbers
    public var episodeCode: String? {
        guard type == .episode,
              let season = parentIndexNumber,
              let episode = indexNumber
        else { return nil }
        return "S\(season)E\(episode)"
    }

    /// Display title for episodes (e.g., "S01E05 - Episode Title")
    public var episodeDisplayTitle: String? {
        guard type == .episode,
              let season = parentIndexNumber,
              let episode = indexNumber else { return nil }

        let seasonStr = String(format: "S%02d", season)
        let episodeStr = String(format: "E%02d", episode)
        return "\(seasonStr)\(episodeStr) - \(name)"
    }
}

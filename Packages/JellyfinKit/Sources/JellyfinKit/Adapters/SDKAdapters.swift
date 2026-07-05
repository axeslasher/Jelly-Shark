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
            serverId: dto.serverID,
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
            runTimeTicks: dto.runTimeTicks.map(Int64.init),
            communityRating: dto.communityRating.map(Double.init),
            criticRating: dto.criticRating.map(Double.init),
            officialRating: dto.officialRating,
            tagline: dto.taglines?.first,
            genres: dto.genres,
            studios: dto.studios?.compactMap(\.name),
            premiereDate: dto.premiereDate,
            endDate: dto.endDate,
            status: dto.status,
            childCount: dto.childCount,
            recursiveItemCount: dto.recursiveItemCount,
            technicalInfo: MediaTechnicalInfo(from: dto),
            imageTags: ImageTags(from: dto.imageTags, backdropTags: dto.backdropImageTags),
            userData: dto.userData.map { UserData(from: $0) },
            seriesId: dto.seriesID,
            seriesName: dto.seriesName,
            seasonId: dto.seasonID,
            seasonName: dto.seasonName,
            indexNumber: dto.indexNumber,
            parentIndexNumber: dto.parentIndexNumber,
            people: dto.people?.enumerated().map { index, person in
                // Some servers omit person IDs. Fall back to a position-based id
                // so `ForEach` identity stays unique — two id-less people must not
                // both map to "". Headshot URLs are unaffected: they require
                // `primaryImageTag`, which servers only send alongside a real id.
                CastMember(
                    id: person.id.flatMap { $0.isEmpty ? nil : $0 } ?? "person-\(index)",
                    name: person.name ?? "",
                    role: person.role,
                    kind: (person.type ?? .unknown).rawValue,
                    primaryImageTag: person.primaryImageTag
                )
            },
            parentArtwork: ParentArtwork(from: dto)
        )
    }
}

// MARK: - ParentArtwork Adapter

extension ParentArtwork {
    /// Nil when the item inherits no ancestor artwork at all, so callers can
    /// treat "has a parentArtwork" as "has at least one fallback".
    init?(from dto: JellyfinAPI.BaseItemDto) {
        let backdropTag = dto.parentBackdropImageTags?.first
        let backdropId = dto.parentBackdropItemID
        let logoTag = dto.parentLogoImageTag
        let logoId = dto.parentLogoItemID
        let seriesPrimary = dto.seriesPrimaryImageTag

        guard (backdropTag != nil && backdropId != nil)
            || (logoTag != nil && logoId != nil)
            || seriesPrimary != nil
        else { return nil }

        self.init(
            backdropItemId: backdropId,
            backdropImageTag: backdropTag,
            logoItemId: logoId,
            logoImageTag: logoTag,
            seriesPrimaryImageTag: seriesPrimary
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

// MARK: - MediaTechnicalInfo Adapter

extension MediaTechnicalInfo {
    /// Distill an item's default media source down to display-ready labels:
    /// the (first) video stream's resolution class, dynamic range, codec, and
    /// frame rate, the default audio stream's format, the unique audio and
    /// subtitle languages, and the source's file facts (name, size, container,
    /// bitrate). Nil when there's nothing displayable.
    init?(from dto: JellyfinAPI.BaseItemDto) {
        // Streams live on the media source; the item-level list is a
        // convenience some responses omit, so prefer the source's.
        let source = dto.mediaSources?.first
        let streams = source?.mediaStreams ?? dto.mediaStreams ?? []

        let video = streams.first { $0.type == .video }
        let audioStreams = streams.filter { $0.type == .audio }
        let audio = audioStreams.first { $0.isDefault == true } ?? audioStreams.first
        let subtitles = streams.filter { $0.type == .subtitle }

        let resolution = video.flatMap(Self.resolutionLabel)
        let range = video.flatMap(Self.videoRangeLabel)
        let audioFormat = audio.flatMap(Self.audioLabel)
        let audioLanguages = Self.languages(of: audioStreams)
        let subtitleLanguages = Self.languages(of: subtitles)
        let fileName = (source?.path ?? dto.path).flatMap(Self.fileName)
        let fileSize = source?.size.map(Int64.init)

        guard resolution != nil || range != nil || audioFormat != nil
            || !audioLanguages.isEmpty || !subtitleLanguages.isEmpty
            || fileName != nil || fileSize != nil
        else {
            return nil
        }

        self.init(
            resolution: resolution,
            videoRange: range,
            audioFormat: audioFormat,
            originalAudioLanguage: Self.languages(of: audio.map { [$0] } ?? []).first,
            audioLanguages: audioLanguages,
            subtitleLanguages: subtitleLanguages,
            hasSDHSubtitles: subtitles.contains { $0.isHearingImpaired == true },
            fileName: fileName,
            fileSizeBytes: fileSize,
            container: (source?.container ?? dto.container).flatMap(Self.containerLabel),
            videoCodec: video.flatMap(Self.videoCodecLabel),
            bitrate: source?.bitrate,
            frameRate: (video?.averageFrameRate ?? video?.realFrameRate).map(Double.init)
        )
    }

    /// Last path component, handling both POSIX and Windows-style server paths.
    private static func fileName(from path: String) -> String? {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }

    /// First container name, uppercased — servers report comma lists like
    /// "mov,mp4,m4a" for some formats.
    private static func containerLabel(from container: String) -> String? {
        let first = container.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first, !first.isEmpty else { return nil }
        return first.uppercased()
    }

    private static func videoCodecLabel(for stream: JellyfinAPI.MediaStream) -> String? {
        guard let codec = stream.codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "mpeg2video": return "MPEG-2"
        case "vc1": return "VC-1"
        default: return codec.uppercased()
        }
    }

    /// Resolution class from pixel dimensions. Thresholds are deliberately
    /// loose (mirroring jellyfin-web) so cropped/anamorphic encodes still
    /// classify as their marketing resolution — a 3840×1600 scope film is "4K".
    private static func resolutionLabel(for stream: JellyfinAPI.MediaStream) -> String? {
        let width = stream.width ?? 0
        let height = stream.height ?? 0
        guard width > 0 || height > 0 else { return nil }

        switch (width, height) {
        case (7600..., _), (_, 4300...):
            return "8K"
        case (3800..., _), (_, 2100...):
            return "4K"
        case (1800..., _), (_, 1000...):
            return "1080p"
        case (1200..., _), (_, 700...):
            return "720p"
        default:
            return "SD"
        }
    }

    private static func videoRangeLabel(for stream: JellyfinAPI.MediaStream) -> String? {
        switch stream.videoRangeType {
        case .dovi, .doviWithHDR10, .doviWithHLG, .doviWithSDR,
             .doviWithEL, .doviWithHDR10Plus, .doviWithELHDR10Plus:
            return "Dolby Vision"
        case .hdr10Plus:
            return "HDR10+"
        case .hdr10:
            return "HDR10"
        case .hlg:
            return "HLG"
        case .sdr:
            return nil
        default:
            // Unknown/invalid range type: fall back to the coarse HDR flag.
            return stream.videoRange == .hdr ? "HDR" : nil
        }
    }

    private static func audioLabel(for stream: JellyfinAPI.MediaStream) -> String? {
        switch stream.audioSpatialFormat {
        case .dolbyAtmos:
            return "Dolby Atmos"
        case .dtsx:
            return "DTS:X"
        default:
            break
        }

        // Channel count over channelLayout: layouts carry noisy variants like
        // "5.1(side)" that don't read as badges.
        switch stream.channels {
        case .some(1): return "Mono"
        case .some(2): return "Stereo"
        case .some(6): return "5.1"
        case .some(8): return "7.1"
        case .some(let channels) where channels > 2: return "\(channels - 1).1"
        default: return nil
        }
    }

    /// Unique languages of the given streams in stream order, localized for
    /// display (Jellyfin reports ISO 639 codes like "eng").
    private static func languages(of streams: [JellyfinAPI.MediaStream]) -> [String] {
        var seen = Set<String>()
        return streams.compactMap { stream in
            guard let code = stream.language, !code.isEmpty,
                  seen.insert(code.lowercased()).inserted
            else { return nil }
            return Locale.current.localizedString(forLanguageCode: code) ?? code
        }
    }
}

// MARK: - ImageTags Adapter

extension ImageTags {
    /// Create ImageTags from the SDK's image tags dictionary
    ///
    /// The server reports backdrops in the separate `BackdropImageTags` array
    /// rather than the `ImageTags` dictionary, so the first backdrop tag is
    /// taken from there when the dictionary has none.
    init?(from tags: [String: String]?, backdropTags: [String]? = nil) {
        let backdrop = tags?["Backdrop"] ?? backdropTags?.first
        guard tags != nil || backdrop != nil else { return nil }

        self.init(
            primary: tags?["Primary"],
            backdrop: backdrop,
            banner: tags?["Banner"],
            thumb: tags?["Thumb"],
            logo: tags?["Logo"]
        )
    }
}

// MARK: - UserData Adapter

extension UserData {
    /// Create UserData from the SDK's UserItemDataDto
    init(from dto: JellyfinAPI.UserItemDataDto) {
        self.init(
            playbackPositionTicks: dto.playbackPositionTicks.map(Int64.init),
            playCount: dto.playCount,
            isFavorite: dto.isFavorite ?? false,
            played: dto.isPlayed ?? false,
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
    /// Create a CollectionType from the SDK's CollectionType
    init(from type: JellyfinAPI.CollectionType?) {
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
//
// NOTE: The SDK doesn't expose a JellyfinAPIError type. Instead it uses:
// - JellyfinClient.ClientError for client-specific errors
// - APIError from the Get library for HTTP errors
// - Standard Swift errors
//
// Error handling in JellyfinClient needs to be updated to handle these types.
// This adapter is removed for now to allow compilation.

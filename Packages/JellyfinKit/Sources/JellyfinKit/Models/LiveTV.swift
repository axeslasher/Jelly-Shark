import Foundation

/// A Live TV channel from the server's tuner list.
public struct LiveChannel: Identifiable, Sendable, Equatable, Hashable {
    public let id: String

    public let name: String

    /// Channel number as the tuner reports it. A string because tuners use
    /// forms like "4.1".
    public let number: String?

    /// Tag of the channel logo, nil when the tuner supplied none
    public let imageTag: String?

    public init(id: String, name: String, number: String? = nil, imageTag: String? = nil) {
        self.id = id
        self.name = name
        self.number = number
        self.imageTag = imageTag
    }

    /// The channel as a playable item. Playback is launched with a
    /// `MediaItem`, and a channel's stream is requested by the channel's id.
    public var asMediaItem: MediaItem {
        MediaItem(id: id, name: name, type: .tvChannel, imageTags: ImageTags(primary: imageTag))
    }
}

/// One scheduled programme on a Live TV channel, from the server's guide data.
public struct LiveProgram: Identifiable, Sendable, Equatable, Hashable {
    public let id: String

    public let channelId: String

    /// Programme title; for an episode, the series name
    public let name: String

    public let episodeTitle: String?

    public let overview: String?

    public let startDate: Date

    public let endDate: Date

    public let genres: [String]

    public let officialRating: String?

    /// Release year, which guides carry for films
    public let productionYear: Int?

    public let seasonNumber: Int?

    public let episodeNumber: Int?

    /// Tag of the programme's primary artwork, nil when the guide carried
    /// none. Usually a portrait poster.
    public let imageTag: String?

    /// Tags of the programme's landscape artwork, when the guide source
    /// supplied any. An XMLTV guide gives the server a single image, so
    /// these are nil there (seen with ErsatzTV on Jellyfin 10.11.11).
    public let thumbImageTag: String?
    public let backdropImageTag: String?

    public init(
        id: String,
        channelId: String,
        name: String,
        episodeTitle: String? = nil,
        overview: String? = nil,
        startDate: Date,
        endDate: Date,
        genres: [String] = [],
        officialRating: String? = nil,
        productionYear: Int? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        imageTag: String? = nil,
        thumbImageTag: String? = nil,
        backdropImageTag: String? = nil,
    ) {
        self.thumbImageTag = thumbImageTag
        self.backdropImageTag = backdropImageTag
        self.id = id
        self.channelId = channelId
        self.name = name
        self.episodeTitle = episodeTitle
        self.overview = overview
        self.startDate = startDate
        self.endDate = endDate
        self.genres = genres
        self.officialRating = officialRating
        self.productionYear = productionYear
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.imageTag = imageTag
    }

    /// Whether the programme is on air at `date`. The end is exclusive so
    /// back-to-back programmes never both claim the same instant.
    public func isAiring(at date: Date) -> Bool {
        startDate <= date && date < endDate
    }

    /// Scheduled length in the "1h 5m" style library items use, to the
    /// nearest minute
    public var formattedRuntime: String {
        let minutes = Int64((endDate.timeIntervalSince(startDate) / 60).rounded())
        return MediaItem.runtimeText(minutes * 60 * 10_000_000)
    }

    /// How far through the programme `date` is, from 0 to 1
    public func progress(at date: Date) -> Double {
        let length = endDate.timeIntervalSince(startDate)
        guard length > 0 else { return 0 }
        return min(max(date.timeIntervalSince(startDate) / length, 0), 1)
    }
}

public extension Sequence<LiveProgram> {
    /// The programme on air at `date` on the given channel, if the guide has one
    func airing(at date: Date, onChannel channelId: String) -> LiveProgram? {
        first { $0.channelId == channelId && $0.isAiring(at: date) }
    }
}

/// An open live stream: what the player loads, and what the server needs
/// echoed back to release the tuner afterwards.
public struct LiveStreamSession: Sendable, Equatable {
    /// The server's own stream for the channel. Never the tuner's address,
    /// which the device often cannot reach.
    public let url: URL

    public let playSessionId: String?

    public let mediaSourceId: String

    /// Identifies the tuner stream the server opened for this session
    public let liveStreamId: String?

    public init(url: URL, playSessionId: String?, mediaSourceId: String, liveStreamId: String?) {
        self.url = url
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.liveStreamId = liveStreamId
    }
}

/// Which play sessions are live streams.
///
/// The server only releases a tuner stream it can match to playback reports
/// carrying the stream's id, so the client remembers the id per play session
/// and adds it to that session's reports. Reports for library items find
/// nothing here and are sent unchanged.
final class LiveStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var liveStreamIds: [String: String] = [:]

    func register(_ session: LiveStreamSession) {
        guard let playSessionId = session.playSessionId, let liveStreamId = session.liveStreamId else { return }
        lock.withLock { liveStreamIds[playSessionId] = liveStreamId }
    }

    func liveStreamId(forPlaySession playSessionId: String?) -> String? {
        guard let playSessionId else { return nil }
        return lock.withLock { liveStreamIds[playSessionId] }
    }

    func forget(playSession playSessionId: String?) {
        guard let playSessionId else { return }
        lock.withLock { liveStreamIds[playSessionId] = nil }
    }
}

enum LiveStreamURL {
    /// Join the server-relative stream path from PlaybackInfo onto the
    /// server's address, keeping any path prefix the server is hosted under.
    static func resolve(serverURL: URL, path: String) -> URL? {
        var base = serverURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))
    }
}

import Foundation
import JellyfinAPI

extension LiveChannel {
    /// Create a LiveChannel from a `/LiveTv/Channels` item
    init?(from dto: JellyfinAPI.BaseItemDto) {
        guard let id = dto.id else { return nil }
        self.init(
            id: id,
            name: dto.name ?? "",
            number: dto.channelNumber ?? dto.number,
            imageTag: dto.imageTags?["Primary"],
        )
    }
}

extension LiveProgram {
    /// Create a LiveProgram from a `/LiveTv/Programs` item. A programme
    /// without a channel or both times cannot be placed on the guide.
    init?(from dto: JellyfinAPI.BaseItemDto) {
        guard let id = dto.id,
              let channelId = dto.channelID,
              let startDate = dto.startDate,
              let endDate = dto.endDate,
              endDate > startDate
        else { return nil }
        self.init(
            id: id,
            channelId: channelId,
            name: dto.name ?? "",
            episodeTitle: dto.episodeTitle,
            overview: dto.overview,
            startDate: startDate,
            endDate: endDate,
            genres: dto.genres ?? [],
            officialRating: dto.officialRating,
            seasonNumber: dto.parentIndexNumber,
            episodeNumber: dto.indexNumber,
            imageTag: dto.imageTags?["Primary"],
        )
    }
}

extension JellyfinAPI.DeviceProfile {
    /// The profile sent for a live channel: the engine's own, narrowed two ways.
    ///
    /// 1. No direct play. With direct play on offer the server hands back
    ///    the tuner's raw address, which the device often cannot reach and
    ///    AVPlayer handles poorly for MPEG-TS tuners; without it the server
    ///    answers with a stream of its own.
    /// 2. HLS in MPEG-TS segments only, and so H.264 only. Offered "mp4" as
    ///    well, the server answers a tuner that disallows MP4 segments (the
    ///    default) with one endless progressive file, not HLS, and AVPlayer
    ///    stops on it within seconds. HEVC is dropped with it: AVPlayer
    ///    plays HEVC over HLS only in MP4 segments.
    ///
    /// Both observed 2026-11-11 against Jellyfin 10.11.11 with an M3U tuner.
    init(liveCapabilities capabilities: PlaybackCapabilities) {
        self.init(capabilities: capabilities)
        directPlayProfiles = []
        transcodingProfiles = transcodingProfiles?.map { profile in
            var live = profile
            live.container = "ts"
            live.videoCodec = "h264"
            return live
        }
    }
}

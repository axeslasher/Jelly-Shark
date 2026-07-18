import Foundation
import JellyfinAPI

extension TrickplayInfo {
    /// Build from the SDK DTO, rejecting entries whose geometry cannot
    /// support resolver math (missing or non-positive fields). Dropping a
    /// malformed entry here is the single guard that keeps divide-by-zero
    /// out of `TrickplayResolver`.
    init?(widthKey: Int, from dto: JellyfinAPI.TrickplayInfoDto) {
        guard let interval = dto.interval, interval > 0,
              let thumbnailWidth = dto.width, thumbnailWidth > 0,
              let thumbnailHeight = dto.height, thumbnailHeight > 0,
              let columns = dto.tileWidth, columns > 0,
              let rows = dto.tileHeight, rows > 0,
              let thumbnailCount = dto.thumbnailCount, thumbnailCount > 0
        else {
            return nil
        }

        self.init(
            widthKey: widthKey,
            thumbnailWidth: thumbnailWidth,
            thumbnailHeight: thumbnailHeight,
            columns: columns,
            rows: rows,
            intervalMilliseconds: interval,
            thumbnailCount: thumbnailCount,
            bandwidth: dto.bandwidth,
        )
    }
}

extension TrickplayManifest {
    /// Build from the item DTO's trickplay dictionary
    /// (media source id → thumbnail width string → info), dropping malformed
    /// entries and sources left empty by them. Returns nil when nothing
    /// usable remains — callers treat that the same as no trickplay data.
    init?(from dto: [String: [String: JellyfinAPI.TrickplayInfoDto]]) {
        var sources: [String: [TrickplayInfo]] = [:]
        for (sourceId, resolutions) in dto {
            let infos = resolutions
                .compactMap { key, value -> TrickplayInfo? in
                    guard let widthKey = Int(key) else { return nil }
                    return TrickplayInfo(widthKey: widthKey, from: value)
                }
                .sorted { $0.widthKey < $1.widthKey }
            if !infos.isEmpty {
                sources[sourceId] = infos
            }
        }

        guard !sources.isEmpty else { return nil }
        self.init(sources: sources)
    }
}

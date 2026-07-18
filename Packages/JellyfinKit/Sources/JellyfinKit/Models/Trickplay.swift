import Foundation

/// Metadata for one trickplay resolution of a media source
///
/// Jellyfin generates trickplay thumbnails as JPEG tile sheets: a grid of
/// small frames sampled at a fixed interval, several sheets per item. The
/// server's vocabulary is misleading — its `TileWidth`/`TileHeight` count
/// thumbnails per row/column, not pixels — so the adapter renames fields to
/// what they actually mean:
///
/// | Server field  | Here              |
/// |---------------|-------------------|
/// | `Width`       | `thumbnailWidth`  |
/// | `Height`      | `thumbnailHeight` |
/// | `TileWidth`   | `columns`         |
/// | `TileHeight`  | `rows`            |
public struct TrickplayInfo: Sendable, Equatable, Hashable {
    /// The resolution key — also the `{width}` path segment in tile URLs
    public let widthKey: Int

    /// Width in pixels of a single thumbnail
    public let thumbnailWidth: Int

    /// Height in pixels of a single thumbnail
    public let thumbnailHeight: Int

    /// Thumbnails per row in a tile sheet
    public let columns: Int

    /// Thumbnails per column in a tile sheet
    public let rows: Int

    /// Milliseconds of content between adjacent thumbnails
    public let intervalMilliseconds: Int

    /// Total number of real (non-padding) thumbnails across all tile sheets
    public let thumbnailCount: Int

    /// Peak bandwidth in bits per second, when the server reports it
    /// (used for the I-frame rendition's BANDWIDTH attribute)
    public let bandwidth: Int?

    public init(
        widthKey: Int,
        thumbnailWidth: Int,
        thumbnailHeight: Int,
        columns: Int,
        rows: Int,
        intervalMilliseconds: Int,
        thumbnailCount: Int,
        bandwidth: Int? = nil,
    ) {
        self.widthKey = widthKey
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.columns = columns
        self.rows = rows
        self.intervalMilliseconds = intervalMilliseconds
        self.thumbnailCount = thumbnailCount
        self.bandwidth = bandwidth
    }
}

/// The trickplay manifest for an item: available resolutions per media source
public struct TrickplayManifest: Sendable, Equatable {
    /// Available trickplay resolutions keyed by media source id,
    /// sorted ascending by `widthKey`
    public let sources: [String: [TrickplayInfo]]

    public init(sources: [String: [TrickplayInfo]]) {
        self.sources = sources
    }

    /// The resolution closest to `preferredWidth` for a media source
    ///
    /// Looks up the exact media source id first. A single-source manifest is
    /// unambiguous, so it also matches when the id differs (the server keys
    /// the manifest itself, and its formatting can diverge from the id
    /// PlaybackInfo hands back).
    ///
    /// - Parameters:
    ///   - id: The media source id playback resolved (`MediaSource.id`)
    ///   - preferredWidth: Desired thumbnail width in pixels; 320 is the
    ///     server's default generated resolution
    /// - Returns: The best-matching resolution, or nil when the source has none
    public func info(forMediaSourceId id: String, preferredWidth: Int = 320) -> TrickplayInfo? {
        let candidates: [TrickplayInfo]? = if let exact = sources[id] {
            exact
        } else if sources.count == 1 {
            sources.values.first
        } else {
            nil
        }

        return candidates?.min { lhs, rhs in
            let lhsDistance = abs(lhs.widthKey - preferredWidth)
            let rhsDistance = abs(rhs.widthKey - preferredWidth)
            return lhsDistance == rhsDistance
                ? lhs.widthKey < rhs.widthKey
                : lhsDistance < rhsDistance
        }
    }
}

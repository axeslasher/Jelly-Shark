import CoreGraphics
import Foundation

/// Where one playback position lives in the trickplay tile sheets
public struct TrickplayTileLocation: Sendable, Equatable {
    /// The tile sheet index — the `{index}` path segment in tile URLs
    public let tileIndex: Int

    /// The thumbnail's crop rectangle in tile-sheet pixel coordinates
    public let cropRect: CGRect

    public init(tileIndex: Int, cropRect: CGRect) {
        self.tileIndex = tileIndex
        self.cropRect = cropRect
    }
}

/// Maps playback positions to trickplay tile sheets
///
/// Pure math with no networking, so it is fully unit-testable. Thumbnails
/// are laid out row-major across fixed-size tile sheets; the last sheet is
/// only partially filled, so positions at or past the end clamp to the last
/// real thumbnail rather than resolving into black padding.
public enum TrickplayResolver {
    /// Locate the thumbnail for a playback position
    /// - Parameters:
    ///   - seconds: Position on the item's original timeline (non-finite or
    ///     negative values clamp to the first thumbnail)
    ///   - info: The trickplay resolution to resolve against
    /// - Returns: The tile sheet index and crop rectangle for the thumbnail
    public static func location(atSeconds seconds: Double, info: TrickplayInfo) -> TrickplayTileLocation {
        let positionMilliseconds = seconds.isFinite ? max(0, seconds * 1000) : 0
        let rawIndex = (positionMilliseconds / Double(info.intervalMilliseconds)).rounded(.down)
        return location(ofThumbnail: Int(min(rawIndex, Double(info.thumbnailCount - 1))), info: info)
    }

    /// Locate a thumbnail by its index (clamped to the valid range)
    /// - Parameters:
    ///   - index: Zero-based thumbnail index
    ///   - info: The trickplay resolution to resolve against
    /// - Returns: The tile sheet index and crop rectangle for the thumbnail
    public static func location(ofThumbnail index: Int, info: TrickplayInfo) -> TrickplayTileLocation {
        let thumbnailIndex = min(max(index, 0), info.thumbnailCount - 1)

        let thumbnailsPerTile = info.columns * info.rows
        let tileIndex = thumbnailIndex / thumbnailsPerTile
        let indexInTile = thumbnailIndex % thumbnailsPerTile
        let row = indexInTile / info.columns
        let column = indexInTile % info.columns

        let cropRect = CGRect(
            x: column * info.thumbnailWidth,
            y: row * info.thumbnailHeight,
            width: info.thumbnailWidth,
            height: info.thumbnailHeight,
        )
        return TrickplayTileLocation(tileIndex: tileIndex, cropRect: cropRect)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Fetches and decodes remote artwork with a bounded decoded-image cache.
///
/// `AsyncImage` keeps its decoded bitmap only while the view is mounted, so
/// every remount during shelf/grid scrolling re-decodes from scratch — the
/// dominant memory churn found in the #105 device profiling. This loader adds
/// the missing tier: encoded bytes ride the app-sized shared `URLCache` (via
/// `URLSession.shared`), and decoded images live in an `NSCache` bounded by
/// byte cost, so paging back over artwork is a lookup instead of a decode.
///
/// Decodes are downsampled through ImageIO to the pixel size the slot actually
/// needs — a guardrail so an oversized source can never inflate a small card
/// into a screen-sized bitmap. When the slot is unknown the image decodes at
/// its native size, which matches the sizes already requested from the server.
public actor ArtworkLoader {
    public static let shared = ArtworkLoader()

    /// Decoded images, keyed by URL + slot. Cost is decoded bytes; the limit
    /// bounds the tier well under the app's overall memory target, and NSCache
    /// additionally evicts on system memory pressure.
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.name = "ArtworkLoader.decoded"
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Coalesces concurrent requests for the same key (e.g. a fast scroll
    /// remounting a card while its first load is still in flight).
    private var inFlight: [NSString: Task<CGImage, any Error>] = [:]

    public struct DecodeFailed: Error {}

    /// Returns the decoded (and, if needed, downsampled) image for `url`.
    ///
    /// `slotPixelSize` is the destination size in *pixels* (points ×
    /// `displayScale`); pass `nil` when unknown to decode at native size.
    public func image(
        at url: URL,
        slotPixelSize: CGSize?,
        contentMode: ContentMode,
    ) async throws -> CGImage {
        let key = Self.cacheKey(url: url, slotPixelSize: slotPixelSize, contentMode: contentMode) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        // Detached so the fetch + decode run in the cooperative pool instead
        // of serializing on this actor; the task is shared by all waiters and
        // runs to completion even if a waiter's view unmounts mid-scroll, so
        // the result still lands in the cache for the next mount.
        let task = Task.detached(priority: .utility) {
            try await Self.fetchAndDecode(url: url, slotPixelSize: slotPixelSize, contentMode: contentMode)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private static func fetchAndDecode(
        url: URL,
        slotPixelSize: CGSize?,
        contentMode: ContentMode,
    ) async throws -> CGImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = downsampledImage(data: data, slotPixelSize: slotPixelSize, contentMode: contentMode) else {
            throw DecodeFailed()
        }
        return image
    }

    /// Decodes `data`, capped so the result is no larger than the slot needs.
    static func downsampledImage(
        data: Data,
        slotPixelSize: CGSize?,
        contentMode: ContentMode,
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let slotPixelSize,
           let cap = targetMaxPixelSize(
               imagePixelSize: imagePixelSize(of: source),
               slotPixelSize: slotPixelSize,
               contentMode: contentMode,
           )
        {
            options[kCGImageSourceThumbnailMaxPixelSize] = cap
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The largest dimension (in pixels) the decode needs so the image still
    /// covers (`.fill`) or fits (`.fit`) the slot, or `nil` when the source is
    /// already small enough that a cap would change nothing. Never upscales.
    static func targetMaxPixelSize(
        imagePixelSize: CGSize,
        slotPixelSize: CGSize,
        contentMode: ContentMode,
    ) -> Int? {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              slotPixelSize.width > 0, slotPixelSize.height > 0 else { return nil }
        let widthRatio = slotPixelSize.width / imagePixelSize.width
        let heightRatio = slotPixelSize.height / imagePixelSize.height
        let scale = contentMode == .fill
            ? max(widthRatio, heightRatio)
            : min(widthRatio, heightRatio)
        guard scale < 1 else { return nil }
        return Int((max(imagePixelSize.width, imagePixelSize.height) * scale).rounded(.up))
    }

    private static func imagePixelSize(of source: CGImageSource) -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return .zero }
        return CGSize(width: width, height: height)
    }

    static func cacheKey(url: URL, slotPixelSize: CGSize?, contentMode: ContentMode) -> String {
        guard let slotPixelSize else { return url.absoluteString }
        let mode = contentMode == .fill ? "fill" : "fit"
        return "\(url.absoluteString)|\(Int(slotPixelSize.width))x\(Int(slotPixelSize.height))|\(mode)"
    }
}

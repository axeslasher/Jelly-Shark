import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import UniformTypeIdentifiers

/// Loads chapter thumbnail data for the player's Chapters panel
///
/// Chapters with a server-extracted image use it directly. Chapters without
/// one fall back to cropping the trickplay thumbnail at their timestamp —
/// chapter-image extraction is off by default on many servers, while
/// trickplay data is what the seek previews already rely on. Chapters with
/// neither source stay title-only.
enum ChapterArtworkLoader {
    /// Jellyfin image responses carry no Cache-Control headers, so cached
    /// data must be preferred explicitly (same policy as trickplay tiles)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = .shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// Fetch thumbnail data for every chapter that has an artwork source
    /// - Parameters:
    ///   - chapters: The item's chapters
    ///   - chapterImageURL: URL of a chapter's server image, nil when the
    ///     chapter has none
    ///   - trickplayInfo: The session's trickplay resolution, when available
    ///   - trickplayTileURL: URL of the trickplay tile sheet at an index
    /// - Returns: JPEG data keyed by `Chapter.imageIndex`; failed fetches are
    ///   dropped silently (they cost one thumbnail, nothing else)
    static func loadArtwork(
        for chapters: [Chapter],
        chapterImageURL: @Sendable (Chapter) -> URL?,
        trickplayInfo: TrickplayInfo?,
        trickplayTileURL: @Sendable (Int) -> URL?,
    ) async -> [Int: Data] {
        var artwork: [Int: Data] = [:]
        // Adjacent chapters usually share a tile sheet; decode each once
        var decodedSheets: [Int: CGImage] = [:]

        for chapter in chapters {
            if Task.isCancelled {
                break
            }

            if let url = chapterImageURL(chapter) {
                artwork[chapter.imageIndex] = try? await data(from: url)
                continue
            }

            guard let info = trickplayInfo else { continue }
            let location = TrickplayResolver.location(atSeconds: chapter.startSeconds, info: info)
            let sheet: CGImage
            if let cached = decodedSheets[location.tileIndex] {
                sheet = cached
            } else if let url = trickplayTileURL(location.tileIndex),
                      let fetched = try? await tileSheet(from: url)
            {
                decodedSheets[location.tileIndex] = fetched
                sheet = fetched
            } else {
                continue
            }

            if let thumbnail = sheet.cropping(to: location.cropRect),
               let jpeg = encodeJPEG(thumbnail)
            {
                artwork[chapter.imageIndex] = jpeg
            }
        }
        return artwork
    }

    /// Fetch raw image data, e.g. the poster for the Info tab's artwork
    static func imageData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        return try? await data(from: url)
    }

    private static func data(from url: URL) async throws -> Data {
        try await session.data(from: url).0
    }

    private static func tileSheet(from url: URL) async throws -> CGImage {
        let data = try await data(from: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary,
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

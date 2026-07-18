import AVFoundation
import AVKit
import Foundation
import JellyfinKit

/// Builds the AVKit-facing metadata for a playback session: chapter
/// navigation markers (tvOS) and the external metadata that populates the
/// player's title view and Info tab
///
/// HLS remux/transcode streams carry none of the source file's embedded
/// metadata, so both surfaces are reconstructed from Jellyfin data. Pure
/// value-in/value-out so the simulator suite can assert on the output
/// without playing anything.
@MainActor
enum PlayerMetadataFactory {
    #if os(tvOS)
        /// The chapter list for the player's Chapters panel
        ///
        /// AVKit honors only the first group in `navigationMarkerGroups`, and a
        /// nil title marks it as the chapter list.
        /// - Parameters:
        ///   - chapters: The item's chapters
        ///   - durationSeconds: Total runtime; chapters starting at or past it
        ///     are dropped, and the last chapter's marker ends there
        ///   - artwork: JPEG thumbnail data keyed by `Chapter.imageIndex`
        /// - Returns: The group, or nil when no usable chapters remain
        static func navigationMarkerGroup(
            chapters: [Chapter],
            durationSeconds: Double,
            artwork: [Int: Data] = [:],
        ) -> AVNavigationMarkersGroup? {
            guard durationSeconds > 0 else { return nil }

            let usable = chapters
                .filter { $0.startSeconds >= 0 && $0.startSeconds < durationSeconds }
                .sorted { $0.startSeconds < $1.startSeconds }
            guard !usable.isEmpty else { return nil }

            let markers = usable.enumerated().map { position, chapter in
                let end = position + 1 < usable.count
                    ? usable[position + 1].startSeconds
                    : durationSeconds

                var items = [metadataItem(.commonIdentifierTitle, value: chapter.name as NSString)]
                if let data = artwork[chapter.imageIndex] {
                    items.append(metadataItem(.commonIdentifierArtwork, value: data as NSData))
                }

                let timescale: Int32 = 600
                return AVTimedMetadataGroup(
                    items: items,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: chapter.startSeconds, preferredTimescale: timescale),
                        end: CMTime(seconds: end, preferredTimescale: timescale),
                    ),
                )
            }

            return AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)
        }
    #endif

    /// External metadata for the title view and native Info tab
    /// - Parameters:
    ///   - item: The playing item
    ///   - artworkData: Poster image data, when already fetched
    /// - Returns: Metadata items for `AVPlayerItem.externalMetadata`
    static func externalMetadata(for item: MediaItem, artworkData: Data? = nil) -> [AVMetadataItem] {
        var items = [metadataItem(.commonIdentifierTitle, value: item.name as NSString)]

        if let subtitle = subtitleText(for: item) {
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, value: subtitle as NSString))
        }
        if let overview = item.overview, !overview.isEmpty {
            items.append(metadataItem(.commonIdentifierDescription, value: overview as NSString))
        }
        if let genres = item.genres, !genres.isEmpty {
            items.append(metadataItem(.quickTimeMetadataGenre, value: genres.joined(separator: ", ") as NSString))
        }
        if let rating = item.officialRating, !rating.isEmpty {
            items.append(metadataItem(.iTunesMetadataContentRating, value: rating as NSString))
        }
        if let artworkData {
            items.append(metadataItem(.commonIdentifierArtwork, value: artworkData as NSData))
        }
        return items
    }

    /// The title view's second line: series context for episodes, the
    /// tagline otherwise
    private static func subtitleText(for item: MediaItem) -> String? {
        if item.type == .episode, let series = item.seriesName {
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                return "\(series) · S\(season)E\(episode)"
            }
            return series
        }
        if let tagline = item.tagline, !tagline.isEmpty {
            return tagline
        }
        return nil
    }

    private static func metadataItem(
        _ identifier: AVMetadataIdentifier,
        value: NSCopying & NSObjectProtocol,
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        // "und" (undetermined) keeps the item visible for every user locale
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }
}

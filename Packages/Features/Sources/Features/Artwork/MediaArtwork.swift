import Foundation
import SwiftUI
import JellyfinKit
import DesignSystem

/// Artwork URL helpers for views
///
/// Each helper returns nil when the item has no tag for the requested image
/// type (or its fallbacks), so views never request images that don't exist
/// and fall back to the themed placeholder instead.
extension JellyfinClientProtocol {
    /// Poster image: Primary, falling back to Thumb (episodes often lack a Primary)
    func posterURL(for item: MediaItem, maxWidth: Int = 600) -> URL? {
        firstImageURL(for: item, types: [.primary, .thumb], maxWidth: maxWidth)
    }

    /// Hero backdrop: Backdrop, falling back to Thumb
    func backdropURL(for item: MediaItem, maxWidth: Int = 1920) -> URL? {
        firstImageURL(for: item, types: [.backdrop, .thumb], maxWidth: maxWidth)
    }

    /// Landscape card image: Thumb, then Backdrop, then Primary
    func landscapeURL(for item: MediaItem, maxWidth: Int = 800) -> URL? {
        firstImageURL(for: item, types: [.thumb, .backdrop, .primary], maxWidth: maxWidth)
    }

    /// Library card image
    func imageURL(for library: Library, maxWidth: Int = 960) -> URL? {
        guard library.primaryImageTag != nil else { return nil }
        return getImageURL(itemId: library.id, imageType: .primary, maxWidth: maxWidth, maxHeight: nil)
    }

    /// URL for the first image type the item actually has a tag for
    private func firstImageURL(for item: MediaItem, types: [ImageType], maxWidth: Int) -> URL? {
        guard let tags = item.imageTags else { return nil }

        for type in types {
            let tag: String?
            switch type {
            case .primary: tag = tags.primary
            case .backdrop: tag = tags.backdrop
            case .banner: tag = tags.banner
            case .thumb: tag = tags.thumb
            case .logo: tag = tags.logo
            default: tag = nil
            }

            if tag != nil {
                return getImageURL(itemId: item.id, imageType: type, maxWidth: maxWidth, maxHeight: nil)
            }
        }

        return nil
    }
}

/// Shelf/grid card builders that map a `MediaItem` onto the design system's
/// `ArtworkShelfItem`, supplying the artwork URL, two-line caption, progress, and
/// the detail-screen destination.
extension MediaItem {
    /// Portrait poster card (2:3). Title is the item name; subtitle is the year.
    @MainActor @ViewBuilder
    func posterShelfItem(client: JellyfinClientProtocol?, width: CGFloat = 200) -> some View {
        ArtworkShelfItem(
            url: client?.posterURL(for: self),
            title: name,
            subtitle: productionYear.map(String.init),
            aspectRatio: 2.0 / 3.0,
            width: width,
            progress: progressPercentage
        ) {
            MediaDetailView(item: self)
        }
    }

    /// Landscape card (16:9). Episodes show the episode title over the series
    /// name; everything else shows the name over the year.
    @MainActor @ViewBuilder
    func landscapeShelfItem(client: JellyfinClientProtocol?, width: CGFloat = 320) -> some View {
        ArtworkShelfItem(
            url: client?.landscapeURL(for: self),
            title: episodeDisplayTitle ?? name,
            subtitle: type == .episode ? seriesName : productionYear.map(String.init),
            aspectRatio: 16.0 / 9.0,
            width: width,
            progress: progressPercentage
        ) {
            MediaDetailView(item: self)
        }
    }
}

import DesignSystem
import Foundation
import JellyfinKit
import SwiftUI

/// Artwork URL helpers for views
///
/// Each helper returns nil when the item has no tag for the requested image
/// type (or its fallbacks), so views never request images that don't exist
/// and fall back to the themed placeholder instead.
extension JellyfinClientProtocol {
    /// Poster image: Primary, falling back to Thumb (episodes often lack a
    /// Primary), then to the series poster
    func posterURL(for item: MediaItem, maxWidth: Int = 600) -> URL? {
        if let own = firstImageURL(for: item, types: [.primary, .thumb], maxWidth: maxWidth) {
            return own
        }
        guard let seriesId = item.seriesId,
              item.parentArtwork?.seriesPrimaryImageTag != nil
        else { return nil }
        return getImageURL(itemId: seriesId, imageType: .primary, maxWidth: maxWidth, maxHeight: nil)
    }

    /// Hero backdrop: Backdrop, falling back to Thumb, then to the nearest
    /// ancestor backdrop (episodes rarely carry their own — without this the
    /// episode hero renders bare)
    func backdropURL(for item: MediaItem, maxWidth: Int = 1920) -> URL? {
        if let own = firstImageURL(for: item, types: [.backdrop, .thumb], maxWidth: maxWidth) {
            return own
        }
        guard let parentId = item.parentArtwork?.backdropItemId,
              item.parentArtwork?.backdropImageTag != nil
        else { return nil }
        return getImageURL(itemId: parentId, imageType: .backdrop, maxWidth: maxWidth, maxHeight: nil)
    }

    /// Landscape card image: Thumb, then Backdrop, then Primary
    func landscapeURL(for item: MediaItem, maxWidth: Int = 800) -> URL? {
        firstImageURL(for: item, types: [.thumb, .backdrop, .primary], maxWidth: maxWidth)
    }

    /// Logo (title treatment) image: the item's own, falling back to the
    /// nearest ancestor logo (episodes inherit the series title treatment)
    func logoURL(for item: MediaItem, maxWidth: Int = 800) -> URL? {
        if item.imageTags?.logo != nil {
            return getImageURL(itemId: item.id, imageType: .logo, maxWidth: maxWidth, maxHeight: nil)
        }
        guard let parentId = item.parentArtwork?.logoItemId,
              item.parentArtwork?.logoImageTag != nil
        else { return nil }
        return getImageURL(itemId: parentId, imageType: .logo, maxWidth: maxWidth, maxHeight: nil)
    }

    /// Library card image
    func imageURL(for library: Library, maxWidth: Int = 960) -> URL? {
        guard library.primaryImageTag != nil else { return nil }
        return getImageURL(itemId: library.id, imageType: .primary, maxWidth: maxWidth, maxHeight: nil)
    }

    /// Headshot for a cast/crew member. Person IDs are item IDs in Jellyfin, so
    /// the standard image endpoint applies; returns nil when there's no photo.
    func headshotURL(for member: CastMember, maxWidth: Int = 300) -> URL? {
        guard member.primaryImageTag != nil, !member.id.isEmpty else { return nil }
        return getImageURL(itemId: member.id, imageType: .primary, maxWidth: maxWidth, maxHeight: nil)
    }

    /// URL for the first image type the item actually has a tag for
    private func firstImageURL(for item: MediaItem, types: [ImageType], maxWidth: Int) -> URL? {
        guard let tags = item.imageTags else { return nil }

        for type in types {
            let tag: String? = switch type {
            case .primary: tags.primary
            case .backdrop: tags.backdrop
            case .banner: tags.banner
            case .thumb: tags.thumb
            case .logo: tags.logo
            default: nil
            }

            if tag != nil {
                return getImageURL(itemId: item.id, imageType: type, maxWidth: maxWidth, maxHeight: nil)
            }
        }

        return nil
    }
}

/// Shelf/grid card builders that map a `MediaItem` onto the design system's
/// `ArtworkShelfItem`, supplying the artwork URL, two-line caption, and progress.
/// Navigation is value-based: the card pushes the item itself, and the enclosing
/// stack's `navigationDestination(for: MediaItem.self)` (registered at each tab's
/// stack root in `RootView`) resolves it to a `MediaDetailView`.
extension MediaItem {
    /// Portrait poster card (2:3). Title is the item name; subtitle is the year.
    @MainActor
    func posterShelfItem(client: JellyfinClientProtocol?, width: CGFloat = 200) -> some View {
        ArtworkShelfItem(
            url: client?.posterURL(for: self),
            blurHash: posterBlurHash,
            title: name,
            subtitle: productionYear.map(String.init),
            aspectRatio: 2.0 / 3.0,
            width: width,
            progress: progressPercentage,
            value: self,
        )
    }

    /// Episode card for a series' Episodes shelf (16:9 still): an "S2E4"
    /// eyebrow over the episode name, a synopsis, and a playback badge
    /// (play/replay + runtime, or progress) — all captions ragged left. Wider than the generic
    /// landscape card: episode stills carry the scene, and roughly
    /// three-and-a-half cards per row reads best at 10 feet.
    /// Unlike the navigation cards, clicking plays the episode immediately.
    /// `showsSeriesName` prefixes the eyebrow with the series name — for
    /// shelves outside a series page, where the episode needs that context.
    @MainActor
    func episodeShelfItem(
        client: JellyfinClientProtocol?,
        width: CGFloat = 440,
        showsSeriesName: Bool = false,
        onPlay: @escaping () -> Void,
    ) -> some View {
        ArtworkShelfItem(
            // 440pt is ~880 physical px on a 4K panel; fetch to match so the
            // still isn't upscaled.
            url: client?.landscapeURL(for: self, maxWidth: 1000),
            blurHash: landscapeBlurHash,
            title: name,
            subtitle: showsSeriesName
                ? [seriesName, episodeCode].compactMap(\.self).joined(separator: " · ")
                : episodeCode,
            synopsis: overview ?? "",
            captionAlignment: .leading,
            subtitleAboveTitle: true,
            placeholderIcon: "play.tv",
            aspectRatio: 16.0 / 9.0,
            width: width,
            playbackBadge: playbackBadge,
            action: onPlay,
        )
    }

    /// Playback state for the episode card's artwork treatment: in-progress
    /// wins (play + progress bar), then played (replay + runtime), else
    /// unplayed (play + runtime).
    private var playbackBadge: PlaybackBadge {
        if hasProgress, let progress = progressPercentage {
            return .inProgress(progress, remaining: formattedRemainingRuntime)
        }
        if userData?.played == true {
            return .played(runtime: formattedRuntime)
        }
        return .unplayed(runtime: formattedRuntime)
    }

    /// Playable landscape card (16:9) shared by Home's Continue Watching and
    /// Next Up rows: episode-shelf width, playback badge (play/replay +
    /// runtime, or play + themed progress bar + remaining), and a leading
    /// caption — the episode title over "Series · S2E4" (movies: title over
    /// year). Clicking plays immediately — the badge is the affordance —
    /// rather than navigating to detail.
    @MainActor
    func playableShelfItem(
        client: JellyfinClientProtocol?,
        width: CGFloat = 440,
        onPlay: @escaping () -> Void,
    ) -> some View {
        ArtworkShelfItem(
            // Fetch to the card's physical size (~880px on a 4K panel) so the
            // still isn't upscaled.
            url: client?.landscapeURL(for: self, maxWidth: 1000),
            blurHash: landscapeBlurHash,
            title: name,
            subtitle: type == .episode
                ? [seriesName, episodeCode].compactMap(\.self).joined(separator: " · ")
                : productionYear.map(String.init),
            captionAlignment: .leading,
            placeholderIcon: "play.tv",
            aspectRatio: 16.0 / 9.0,
            width: width,
            playbackBadge: playbackBadge,
            action: onPlay,
        )
    }

    /// Landscape card (16:9). Episodes show the episode title over the series
    /// name; everything else shows the name over the year.
    @MainActor
    func landscapeShelfItem(client: JellyfinClientProtocol?, width: CGFloat = 320) -> some View {
        ArtworkShelfItem(
            url: client?.landscapeURL(for: self),
            blurHash: landscapeBlurHash,
            title: episodeDisplayTitle ?? name,
            subtitle: type == .episode ? seriesName : productionYear.map(String.init),
            aspectRatio: 16.0 / 9.0,
            width: width,
            progress: progressPercentage,
            value: self,
        )
    }
}

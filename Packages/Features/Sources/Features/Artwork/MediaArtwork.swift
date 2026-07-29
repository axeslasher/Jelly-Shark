import DesignSystem
import Foundation
import JellyfinKit
import SwiftUI

/// Which stored image an artwork slot resolved to: the item that owns it (not
/// always the item asked about — episodes inherit ancestor artwork) and the
/// image type. Separated from the URL so a *chosen* image can be persisted as
/// an identity and rebuilt against whatever server address the session has
/// later, rather than as a baked absolute URL (genre cards, #124).
struct ArtworkSlot: Equatable, Sendable {
    let itemId: String
    let imageType: ImageType
}

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
        backdropSlot(for: item).map {
            getImageURL(itemId: $0.itemId, imageType: $0.imageType, maxWidth: maxWidth, maxHeight: nil)
        }
    }

    /// The stored image `backdropURL(for:)` resolves to, before it becomes a
    /// URL — the same backdrop → thumb → ancestor-backdrop fallback chain,
    /// expressed as an identity a caller can persist.
    func backdropSlot(for item: MediaItem) -> ArtworkSlot? {
        if let own = firstImageSlot(for: item, types: [.backdrop, .thumb]) {
            return own
        }
        guard let parentId = item.parentArtwork?.backdropItemId,
              item.parentArtwork?.backdropImageTag != nil
        else { return nil }
        return ArtworkSlot(itemId: parentId, imageType: .backdrop)
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
        firstImageSlot(for: item, types: types).map {
            getImageURL(itemId: $0.itemId, imageType: $0.imageType, maxWidth: maxWidth, maxHeight: nil)
        }
    }

    /// The first image type the item actually has a tag for
    private func firstImageSlot(for item: MediaItem, types: [ImageType]) -> ArtworkSlot? {
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
                return ArtworkSlot(itemId: item.id, imageType: type)
            }
        }

        return nil
    }
}

/// How long a navigating context-menu action waits for tvOS to finish
/// dismissing the menu and putting the lifted card back before it pushes.
///
/// Not a design value — it has to outlast a system animation the app does not
/// own and cannot observe the end of (SwiftUI's `contextMenu` exposes no
/// dismissal callback), so it is a measured floor rather than a chosen
/// duration. The oracle is the log: too short and UIKit resumes emitting
/// `setPresentationValue is called outside of supported contexts, ignoring`
/// from `com.apple.UIKit.AnimationKit`, with the stranded card visible for
/// exactly as long as those faults continue.
private let contextMenuDismissalSettle: Duration = .milliseconds(350)

/// The owning screen's handlers for a shelf card's long-press context menu.
/// Each nil handler omits its menu entry, so reused cards stay contextual
/// (e.g. no View Details on a card whose select already navigates).
struct ShelfMenuHandlers {
    /// Navigate to the item's detail page — the only path to detail from
    /// cards that play on select.
    var viewDetails: (@MainActor () -> Void)?
    /// Apply the given watched state (the menu derives "Mark Watched" vs
    /// "Mark Unwatched" from the item's current state).
    var setPlayed: (@MainActor (Bool) -> Void)?
    /// Apply the given favorite state.
    var setFavorite: (@MainActor (Bool) -> Void)?

    init(
        viewDetails: (@MainActor () -> Void)? = nil,
        setPlayed: (@MainActor (Bool) -> Void)? = nil,
        setFavorite: (@MainActor (Bool) -> Void)? = nil,
    ) {
        self.viewDetails = viewDetails
        self.setPlayed = setPlayed
        self.setFavorite = setFavorite
    }

    /// Copy without the View Details entry, for cards that already navigate
    /// on select (posters) where the entry would be redundant.
    var withoutViewDetails: ShelfMenuHandlers {
        var copy = self
        copy.viewDetails = nil
        return copy
    }
}

extension MediaItem {
    /// Maps the handlers onto concrete menu entries, deriving the toggle
    /// labels from this item's current user data.
    @MainActor
    func shelfMenuActions(_ handlers: ShelfMenuHandlers?) -> [ShelfMenuAction] {
        guard let handlers else { return [] }
        var actions: [ShelfMenuAction] = []
        if let setPlayed = handlers.setPlayed {
            let played = userData?.played == true
            actions.append(ShelfMenuAction(
                title: played ? "Mark Unwatched" : "Mark Watched",
                systemImage: played ? "eye.slash.fill" : "eye.fill",
            ) {
                setPlayed(!played)
            })
        }
        if let viewDetails = handlers.viewDetails {
            actions.append(ShelfMenuAction(
                title: "View Details",
                systemImage: "info.circle.text.page.fill",
            ) {
                // Deferred, unlike the toggles above, because this one
                // navigates. tvOS lifts the pressed card into a system
                // presentation for the menu and animates it back on dismiss;
                // pushing synchronously here replaces the hierarchy that
                // animation is returning into, so UIKit spends the rest of it
                // logging "setPresentationValue is called outside of
                // supported contexts, ignoring" (AnimationKit) and the lifted
                // card is left painted over the detail page for as long as
                // the orphaned animation runs.
                //
                // The toggles need no deferral: they mutate state in place,
                // so the card is still there to animate back into — and
                // delaying their optimistic feedback would be a regression.
                Task { @MainActor in
                    try? await Task.sleep(for: contextMenuDismissalSettle)
                    viewDetails()
                }
            })
        }
        if let setFavorite = handlers.setFavorite {
            let favorite = userData?.isFavorite == true
            actions.append(ShelfMenuAction(
                title: favorite ? "Unfavorite" : "Favorite",
                systemImage: favorite ? "heart.slash.fill" : "heart.fill",
            ) {
                setFavorite(!favorite)
            })
        }
        return actions
    }
}

/// Shelf/grid card builders that map a `MediaItem` onto the design system's
/// `ArtworkShelfItem`, supplying the artwork URL, two-line caption, and progress.
/// Navigation is value-based: the card pushes the item itself, and the enclosing
/// stack's `navigationDestination(for: MediaItem.self)` (registered at each tab's
/// stack root in `RootView`) resolves it to a `MediaDetailView`.
extension MediaItem {
    /// Portrait poster card (2:3). Title is the item name; subtitle is the
    /// year. `countBadge` overlays a count on the poster's top-trailing
    /// corner (unwatched episodes on a series card).
    @MainActor
    func posterShelfItem(
        client: JellyfinClientProtocol?,
        width: CGFloat = 200,
        countBadge: Int? = nil,
        menu: ShelfMenuHandlers? = nil,
    ) -> some View {
        ArtworkShelfItem(
            url: client?.posterURL(for: self),
            blurHash: posterBlurHash,
            title: name,
            subtitle: productionYear.map(String.init),
            aspectRatio: 2.0 / 3.0,
            width: width,
            progress: progressPercentage,
            countBadge: countBadge,
            menuActions: shelfMenuActions(menu?.withoutViewDetails),
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
        menu: ShelfMenuHandlers? = nil,
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
            menuActions: shelfMenuActions(menu),
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
        menu: ShelfMenuHandlers? = nil,
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
            menuActions: shelfMenuActions(menu),
            action: onPlay,
        )
    }

    /// Landscape card (16:9), the navigational counterpart to
    /// `playableShelfItem` — same caption lockup, no play affordance.
    ///
    /// Episodes lead with the episode name over "Series · S2E4"; everything
    /// else shows the name over the year. Deliberately *not*
    /// `episodeDisplayTitle`, which bakes the code into the title as
    /// "S10E18 - Simpsons Bible Stories": at this width the code eats the
    /// front of the line and the truncation then eats the name, so the card
    /// spends its one title line saying almost nothing. The code belongs in
    /// the subtitle beside the series it qualifies.
    @MainActor
    func landscapeShelfItem(client: JellyfinClientProtocol?, width: CGFloat = 320) -> some View {
        ArtworkShelfItem(
            url: client?.landscapeURL(for: self),
            blurHash: landscapeBlurHash,
            title: name,
            subtitle: type == .episode
                ? [seriesName, episodeCode].compactMap(\.self).joined(separator: " · ")
                : productionYear.map(String.init),
            // Ragged left, matching Home's rows. Centred captions read as a
            // caption *about* the card; leading ones read as the card's own
            // label, and a truncated centre-aligned title looks like a layout
            // fault rather than an intended clip.
            captionAlignment: .leading,
            aspectRatio: 16.0 / 9.0,
            width: width,
            progress: progressPercentage,
            value: self,
        )
    }
}

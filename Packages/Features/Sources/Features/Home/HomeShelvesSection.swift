import DesignSystem
import JellyfinKit
import SwiftUI

/// The below-the-fold Home shelves: Continue Watching, Next Up, and one
/// Recently Added row per movie/TV/collection library.
///
/// Sections degrade deliberately: a failed section keeps its header with an
/// inline notice instead of vanishing, while an empty section (nothing to
/// resume, no next-up) simply doesn't render — that's normal, not an error.
struct HomeShelvesSection: View {
    @Environment(AppSession.self) private var session

    let resumeItems: [MediaItem]
    let nextUpItems: [MediaItem]
    let latestShelves: [HomeViewModel.LibraryShelf]
    let resumeStatus: HomeViewModel.SectionStatus
    let nextUpStatus: HomeViewModel.SectionStatus
    let latestStatus: HomeViewModel.SectionStatus
    /// The first shelf peeks above the fold under the hero; its header stays
    /// hidden until the hero has (mostly) exited, then fades/slides in.
    let showsResumeHeader: Bool
    /// Continue Watching and Next Up cards play immediately (the playback
    /// badge is the affordance); the owner presents the player.
    let onPlay: (MediaItem) -> Void

    /// Measured section width, feeding the shared poster-column math so
    /// Recently Added posters match the library grid's card size exactly.
    @State private var sectionWidth: CGFloat = 0

    /// The library grid measures its width inside the screen padding; the
    /// shelves span the full container (padding lives inside `ContentShelf`),
    /// so subtract it here to run the same math on the same span.
    private var posterWidth: CGFloat {
        guard sectionWidth > 0 else { return PosterGridLayout.minimumCardWidth }
        return PosterGridLayout.columns(for: sectionWidth - SpacingTokens.screenPadding * 2).width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            if !resumeItems.isEmpty {
                ContentShelf("Continue Watching", icon: "popcorn.fill", headerVisible: showsResumeHeader) {
                    ForEach(resumeItems) { item in
                        item.playableShelfItem(client: session.client) {
                            onPlay(item)
                        }
                    }
                }
            } else if resumeStatus.isFailed {
                FailedShelfNotice(title: "Continue Watching", icon: "popcorn.fill")
            }

            if !nextUpItems.isEmpty {
                ContentShelf("Next Up", icon: "play.square.stack") {
                    ForEach(nextUpItems) { item in
                        item.playableShelfItem(client: session.client) {
                            onPlay(item)
                        }
                    }
                }
            } else if nextUpStatus.isFailed {
                FailedShelfNotice(title: "Next Up", icon: "play.square.stack")
            }

            ForEach(latestShelves) { shelf in
                ContentShelf("Recently Added \(shelf.library.name)", icon: "sparkles") {
                    ForEach(shelf.items) { item in
                        item.posterShelfItem(
                            client: session.client,
                            width: posterWidth,
                            countBadge: unwatchedBadge(for: item, in: shelf),
                        )
                    }
                }
            }
            if latestShelves.isEmpty, latestStatus.isFailed {
                FailedShelfNotice(title: "Recently Added", icon: "sparkles")
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            sectionWidth = width
        }
    }

    /// TV shelves badge each series poster with its unwatched-episode count
    /// (the server's `UnplayedItemCount`), hidden at zero — the badge marks
    /// something new to watch, not bookkeeping.
    private func unwatchedBadge(for item: MediaItem, in shelf: HomeViewModel.LibraryShelf) -> Int? {
        guard shelf.library.collectionType == .tvshows,
              let count = item.userData?.unplayedItemCount, count > 0
        else { return nil }
        return count
    }
}

/// A section that failed to load: the shelf header stays (mirroring
/// `ContentShelf`'s) with a one-line, non-focusable notice where the cards
/// would be.
private struct FailedShelfNotice: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            HStack(spacing: SpacingTokens.xs) {
                Image(systemName: icon)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .jsStyle(.headline)
                    .foregroundStyle(theme.primary)
            }

            Label("Couldn't load — check your connection", systemImage: "wifi.exclamationmark")
                .jsStyle(.body)
                .foregroundStyle(theme.tertiary)
                .padding(.vertical, SpacingTokens.md)
        }
        .padding(.horizontal, SpacingTokens.screenPadding)
    }
}

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
    /// Continue Watching and Next Up cards play immediately (the playback
    /// badge is the affordance); the owner presents the player.
    let onPlay: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            if !resumeItems.isEmpty {
                ContentShelf("Continue Watching", icon: "play.circle.fill") {
                    ForEach(resumeItems) { item in
                        item.resumeShelfItem(client: session.client) {
                            onPlay(item)
                        }
                    }
                }
            } else if resumeStatus.isFailed {
                FailedShelfNotice(title: "Continue Watching", icon: "play.circle.fill")
            }

            if !nextUpItems.isEmpty {
                ContentShelf("Next Up", icon: "play.square.stack") {
                    ForEach(nextUpItems) { item in
                        item.episodeShelfItem(client: session.client, showsSeriesName: true) {
                            onPlay(item)
                        }
                    }
                }
            } else if nextUpStatus.isFailed {
                FailedShelfNotice(title: "Next Up", icon: "play.square.stack")
            }

            ForEach(latestShelves) { shelf in
                ContentShelf("Recently Added · \(shelf.library.name)", icon: "sparkles") {
                    ForEach(shelf.items) { item in
                        item.posterShelfItem(client: session.client)
                    }
                }
            }
            if latestShelves.isEmpty, latestStatus.isFailed {
                FailedShelfNotice(title: "Recently Added", icon: "sparkles")
            }
        }
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

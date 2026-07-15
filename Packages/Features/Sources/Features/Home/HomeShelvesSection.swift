import DesignSystem
import JellyfinKit
import SwiftUI

/// The below-the-fold Home shelves: Continue Watching (one merged lane by
/// default, or split into Continue Watching + Next Up per the Settings
/// preference) and one Recently Added row per movie/TV/collection library.
///
/// Sections degrade deliberately: a failed section keeps its header with an
/// inline notice instead of vanishing, while an empty section (nothing to
/// resume, no next-up) simply doesn't render — that's normal, not an error.
struct HomeShelvesSection: View {
    @Environment(AppSession.self) private var session

    /// Single-lane vs two-shelf rendering — the user's Settings choice.
    /// Both sets of inputs are always supplied (the view model loads every
    /// source regardless), so flipping the preference re-renders instantly
    /// without a refetch.
    let mergesContinueWatching: Bool
    let mergedItems: [MediaItem]
    let mergedStatus: HomeViewModel.SectionStatus
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
    /// Retry action for the failed-section notices; re-runs just the failed
    /// loads (`HomeViewModel.retryFailedSections`).
    let onRetry: () -> Void

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
            if mergesContinueWatching {
                // One lane, both sources. Partial results beat an error: the
                // notice only appears when nothing rendered and a source
                // failed (mergedStatus's contract).
                if !mergedItems.isEmpty {
                    ContentShelf("Continue Watching", icon: "popcorn.fill", headerVisible: showsResumeHeader) {
                        ForEach(mergedItems) { item in
                            item.playableShelfItem(client: session.client) {
                                onPlay(item)
                            }
                        }
                    }
                } else if mergedStatus.isFailed {
                    FailedShelfNotice(title: "Continue Watching", icon: "popcorn.fill", retry: onRetry)
                }
            } else {
                if !resumeItems.isEmpty {
                    ContentShelf("Continue Watching", icon: "popcorn.fill", headerVisible: showsResumeHeader) {
                        ForEach(resumeItems) { item in
                            item.playableShelfItem(client: session.client) {
                                onPlay(item)
                            }
                        }
                    }
                } else if resumeStatus.isFailed {
                    FailedShelfNotice(title: "Continue Watching", icon: "popcorn.fill", retry: onRetry)
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
                    FailedShelfNotice(title: "Next Up", icon: "play.square.stack", retry: onRetry)
                }
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
                FailedShelfNotice(title: "Recently Added", icon: "sparkles", retry: onRetry)
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

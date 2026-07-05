import DesignSystem
import JellyfinKit
import SwiftUI

/// Seasons and episodes for a series detail page: one continuous episode shelf
/// spanning every season, with a row of season "anchor links" above it.
///
/// Scrolling the shelf flows straight from a season's last episode into the
/// next season's first (and back). The season pills don't gate content —
/// *focusing* one scrolls its first episode into view, like a horizontal
/// anchor link, and the accent tracks whichever season the shelf is actually
/// in (via the focused episode).
///
/// Renders nothing while the series' seasons haven't loaded, so the call site
/// can mount it unconditionally.
struct EpisodesSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let seasons: [MediaItem]
    /// Every episode of the series, in series order (season by season)
    let episodes: [MediaItem]
    /// Clicking an episode card plays it immediately via the owner's player
    @Binding var playbackItem: MediaItem?

    /// Which season pill owns focus; focusing one anchors the shelf to that
    /// season's first episode.
    @FocusState private var focusedSeasonId: String?

    /// Which episode card owns focus; drives the pills' accent so the
    /// highlighted season follows the scroll.
    @FocusState private var focusedEpisodeId: String?

    /// Programmatic handle for the anchor scrolls.
    @State private var shelfPosition = ScrollPosition()

    /// The season the shelf is currently "in" — updated when an episode gains
    /// focus and when an anchor jump fires, and *remembered* when focus leaves
    /// the section so the accent doesn't snap back to Season 1.
    @State private var currentSeasonId: String?

    /// Pending debounced anchor jump (see `onChange(of: focusedSeasonId)`).
    @State private var anchorTask: Task<Void, Never>?

    /// How long a pill must hold focus before the shelf anchors to it —
    /// traversing the pill row shouldn't fire a jump per pill passed through.
    private static let anchorDebounce: Duration = .milliseconds(250)

    var body: some View {
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
                HStack(spacing: SpacingTokens.xs) {
                    Image(systemName: "play.tv.fill")
                        .foregroundStyle(theme.accent)
                    Text("Episodes")
                        .font(theme.jsHeadline)
                        .foregroundStyle(theme.primary)
                }
                .padding(.horizontal, SpacingTokens.screenPadding)

                seasonAnchors

                episodeShelf
            }
            // Anchor on focus, not on click — debounced so swiping across
            // the pill row settles into one jump for the pill you land on,
            // not one per pill passed through.
            .onChange(of: focusedSeasonId) { _, seasonId in
                anchorTask?.cancel()
                guard let seasonId else { return }
                anchorTask = Task {
                    try? await Task.sleep(for: Self.anchorDebounce)
                    guard !Task.isCancelled else { return }
                    scrollToSeason(seasonId)
                }
            }
            // Follow the scroll: an episode gaining focus hands its season
            // the accent, in either direction.
            .onChange(of: focusedEpisodeId) { _, episodeId in
                guard let episodeId,
                      let seasonId = episodes.first(where: { $0.id == episodeId })?.seasonId
                else { return }
                currentSeasonId = seasonId
            }
        }
    }

    private var seasonAnchors: some View {
        ScrollView(.horizontal) {
            HStack(spacing: SpacingTokens.sm) {
                ForEach(seasons) { season in
                    Button {
                        // Click jumps immediately, skipping any pending
                        // debounce — it's the most deliberate signal there is.
                        anchorTask?.cancel()
                        scrollToSeason(season.id)
                    } label: {
                        Text(season.name)
                            .font(theme.jsBody)
                            .fontWeight(.semibold)
                            .foregroundStyle(
                                season.id == (currentSeasonId ?? seasons.first?.id)
                                    ? theme.accent : theme.primary
                            )
                    }
                    .glassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .focused($focusedSeasonId, equals: season.id)
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.focusPadding)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }

    private var episodeShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                ForEach(episodes) { episode in
                    episode.episodeShelfItem(client: session.client) {
                        playbackItem = episode
                    }
                    .focused($focusedEpisodeId, equals: episode.id)
                }
            }
            // Required for the id-based anchor scrolls to resolve.
            .scrollTargetLayout()
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.focusPadding)
        }
        .scrollPosition($shelfPosition)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }

    private func scrollToSeason(_ seasonId: String) {
        guard let first = episodes.first(where: { $0.seasonId == seasonId }) else { return }
        currentSeasonId = seasonId
        withAnimation(theme.animation) {
            shelfPosition.scrollTo(id: first.id, anchor: .leading)
        }
    }
}

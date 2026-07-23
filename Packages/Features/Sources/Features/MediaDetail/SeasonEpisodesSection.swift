import DesignSystem
import JellyfinKit
import SwiftUI

/// The rest of the season on an episode detail page: one shelf of the
/// season's episodes (the page's own episode included), pre-parked on the
/// page's episode so its neighbors are what's on screen — not episode 1.
///
/// A trimmed-down `EpisodesSection`: same card treatment, parking math, and
/// first-focus steer, without the season-anchor row (one season needs no
/// anchors). Renders nothing while the episodes haven't loaded, so the call
/// site can mount it unconditionally.
struct SeasonEpisodesSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    /// Shelf header — the season's name ("Season 2"), falling back to
    /// "Episodes" when the season is unnamed.
    let title: String
    /// The season's episodes, in season order
    let episodes: [MediaItem]
    /// The page's own episode: where the shelf parks and first focus lands
    let currentEpisodeId: String
    /// Whether the below-the-fold focus region owns focus (from the owner's
    /// region tracking). The rising edge steers first focus onto the parked
    /// episode.
    let isRegionFocused: Bool
    /// Long-press menu handlers per episode (view details / watched /
    /// favorite), built by the owner. Episode cards play on select, so the
    /// menu is the only path from here to a sibling's own detail page.
    let menu: (MediaItem) -> ShelfMenuHandlers
    /// Clicking an episode card plays it immediately via the owner's player
    @Binding var playbackItem: MediaItem?

    /// Which episode card owns focus; written once on region entry to steer
    /// first focus onto the parked episode.
    @FocusState private var focusedEpisodeId: String?

    /// One-shot: after the first steer, later hero→shelves re-entries let the
    /// engine restore the last-focused card instead of re-yanking to the
    /// parked one.
    @State private var hasSteered = false

    /// Programmatic handle for the parking scroll.
    @State private var shelfPosition = ScrollPosition()

    /// Card width, owned here because parking is computed geometrically from
    /// it (index × (width + gap)) — id-based scrolls need
    /// `scrollTargetLayout`, which hijacks Siri Remote pans on hardware and
    /// can't resolve cards the lazy stack hasn't built. Matches
    /// `EpisodesSection`.
    private static let episodeCardWidth: CGFloat = 440

    /// Container width for the trailing runway (see `episodeShelf`).
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
                // ContentShelf's header treatment, kept local because the
                // shelf itself can't be a ContentShelf (parking needs the
                // scroll position handle).
                HStack(spacing: SpacingTokens.xs) {
                    Image(systemName: "square.stack.fill")
                        .foregroundStyle(theme.accent)
                    Text(title)
                        .jsStyle(.headline)
                        .foregroundStyle(theme.primary)
                }
                .padding(.horizontal, SpacingTokens.screenPadding)

                episodeShelf
            }
            // First entry into the below-fold region: steer focus onto the
            // parked episode, so the engine doesn't grab whatever card the
            // resting scroll happens to left-align.
            .onChange(of: isRegionFocused) { _, entered in
                guard entered, !hasSteered, focusedEpisodeId == nil else { return }
                focusedEpisodeId = currentEpisodeId
                hasSteered = true
            }
            // Pre-park on the page's episode (unanimated — setup, not a
            // transition) so its neighbors are the shelf's first frame.
            .task(id: episodes.map(\.id)) {
                guard focusedEpisodeId == nil,
                      let index = episodes.firstIndex(where: { $0.id == currentEpisodeId })
                else { return }
                parkShelf(atEpisodeIndex: index)
            }
        }
    }

    private var episodeShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                ForEach(episodes) { episode in
                    episode.episodeShelfItem(
                        client: session.client,
                        width: Self.episodeCardWidth,
                        menu: menu(episode),
                    ) {
                        playbackItem = episode
                    }
                    .focused($focusedEpisodeId, equals: episode.id)
                }
            }
            .padding(.leading, SpacingTokens.screenPadding)
            // Trailing runway: enough room past the last card that a
            // season-finale page can still park its episode at the far left
            // — without it, the park clamps short. Mirrors `EpisodesSection`.
            .padding(.trailing, max(
                SpacingTokens.screenPadding,
                containerWidth - Self.episodeCardWidth - SpacingTokens.screenPadding,
            ))
            .padding(.vertical, SpacingTokens.focusPadding)
        }
        .scrollPosition($shelfPosition)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width
        } action: { _, width in
            containerWidth = width
        }
    }

    /// Scroll so the episode at `index` sits on the shelf's screen-padding
    /// boundary. Pure arithmetic — cards are fixed-width — so it's exact
    /// regardless of what the lazy stack has built (see
    /// `EpisodesSection.parkShelf`).
    private func parkShelf(atEpisodeIndex index: Int) {
        let x = CGFloat(index) * (Self.episodeCardWidth + SpacingTokens.cardGap)
        shelfPosition.scrollTo(x: max(0, x))
    }
}

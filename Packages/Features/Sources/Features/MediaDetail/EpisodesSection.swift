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
/// Focus choreography (tvOS): the shelf pre-parks on the most relevant episode
/// (`initialEpisodeId` — the same next-up logic as the hero Play button), and
/// the anchor row starts invisible (opacity-0 controls are unfocusable on
/// tvOS, and the row only becomes a focus section once revealed, so the hidden
/// row can't dead-end the engine's search). The first entry into the region is
/// steered programmatically onto that episode via `isRegionFocused`; the
/// anchors then fade/slide in and stay. Entering the pill row from outside is
/// redirected to the *active* season's pill rather than the geometrically
/// nearest one, and re-focusing the active pill doesn't re-anchor the shelf.
///
/// Renders nothing while the series' seasons haven't loaded, so the call site
/// can mount it unconditionally.
struct EpisodesSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let seasons: [MediaItem]
    /// Every episode of the series, in series order (season by season)
    let episodes: [MediaItem]
    /// Where the shelf pre-parks: the most relevant episode (next up, else the
    /// first). Focus lands here on first entry from the hero.
    let initialEpisodeId: String?
    /// Whether the below-the-fold focus region owns focus (from the owner's
    /// region tracking). The rising edge steers first focus onto the parked
    /// episode — the engine can't be trusted to find it on its own.
    let isRegionFocused: Bool
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

    /// The anchor row starts hidden on tvOS (making it unfocusable) so the
    /// first press down from the hero lands on the pre-parked episode; it
    /// reveals once an episode has focus and stays. Other platforms have no
    /// focus-driven entry to choreograph, so the row is always visible there.
    #if os(tvOS)
    @State private var anchorsRevealed = false
    #else
    @State private var anchorsRevealed = true
    #endif

    /// How long a pill must hold focus before the shelf anchors to it —
    /// traversing the pill row shouldn't fire a jump per pill passed through.
    private static let anchorDebounce: Duration = .milliseconds(250)

    var body: some View {
        if !seasons.isEmpty {
            // No "Episodes" title — the season anchors are the header. The
            // top padding stands in for the headroom a title used to provide:
            // without it a focused pill sits flush at the parked viewport top
            // and the focus engine nudges the page to give it margin.
            VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
                // The row becomes a focus section only once revealed — a
                // hidden (unfocusable) focus section dead-ends the engine's
                // downward search from the hero.
                Group {
                    #if os(tvOS)
                    if anchorsRevealed {
                        seasonAnchors.focusSection()
                    } else {
                        seasonAnchors
                    }
                    #else
                    seasonAnchors
                    #endif
                }
                .opacity(anchorsRevealed ? 1 : 0)
                .offset(y: anchorsRevealed ? 0 : SpacingTokens.md)

                episodeShelf
            }
            .padding(.top, SpacingTokens.xl)
            // Anchor on focus, not on click — debounced so swiping across
            // the pill row settles into one jump for the pill you land on,
            // not one per pill passed through. Re-focusing the season the
            // shelf is already in doesn't re-anchor (coming up from an
            // episode shouldn't move the shelf underneath it).
            .onChange(of: focusedSeasonId) { oldValue, seasonId in
                anchorTask?.cancel()
                guard let seasonId else { return }
                // Backstop: entry should only be able to land on the active
                // pill (the others aren't focusable from outside), but if the
                // engine slips through anyway, redirect.
                if oldValue == nil, let currentSeasonId, seasonId != currentSeasonId {
                    focusedSeasonId = currentSeasonId
                    return
                }
                guard seasonId != currentSeasonId else { return }
                anchorTask = Task {
                    try? await Task.sleep(for: Self.anchorDebounce)
                    guard !Task.isCancelled else { return }
                    scrollToSeason(seasonId)
                }
            }
            // Follow the scroll: an episode gaining focus hands its season
            // the accent (in either direction) and reveals the anchor row.
            .onChange(of: focusedEpisodeId) { _, episodeId in
                guard let episodeId else { return }
                if let seasonId = episodes.first(where: { $0.id == episodeId })?.seasonId {
                    currentSeasonId = seasonId
                }
                if !anchorsRevealed {
                    withAnimation(theme.animation) {
                        anchorsRevealed = true
                    }
                }
            }
            // First entry into the below-fold region: steer focus onto the
            // parked episode. Without this the engine sometimes targets the
            // (empty, hidden) pill row's space or skips to the cast shelf.
            // Post-reveal entries are left to the engine — the pills are
            // focusable by then and intercept on purpose.
            .onChange(of: isRegionFocused) { _, entered in
                guard entered, !anchorsRevealed, focusedEpisodeId == nil else { return }
                focusedEpisodeId = initialEpisodeId
            }
            // Pre-park the shelf on the most relevant episode (unanimated —
            // this is setup, not a transition) so the focus engine's first
            // entry finds it at the leading edge. Skipped once the user is
            // actually in the shelf.
            .task(id: initialEpisodeId) {
                guard let initialEpisodeId,
                      focusedEpisodeId == nil, !anchorsRevealed,
                      let episode = episodes.first(where: { $0.id == initialEpisodeId })
                else { return }
                currentSeasonId = episode.seasonId
                shelfPosition.scrollTo(id: initialEpisodeId, anchor: .leading)
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
                            .font(theme.jsTitle)
                            .fontWeight(.semibold)
                            .foregroundStyle(
                                season.id == (currentSeasonId ?? seasons.first?.id)
                                    ? theme.accent : theme.primary
                            )
                    }
                    .glassButtonStyle()
                    .buttonBorderShape(.capsule)
                    // From outside the row, only the active season's pill can
                    // take focus — entry always lands on the right pill with
                    // no visible redirect. Inside the row every pill is
                    // focusable so swiping works normally. The `focused`
                    // binding sits OUTSIDE the gate: `.focusable` interposes
                    // its own focus node, and binding inside it never fires —
                    // which would leave the gate stuck shut.
                    .focusable(
                        focusedSeasonId != nil
                            || season.id == (currentSeasonId ?? seasons.first?.id)
                    )
                    .focused($focusedSeasonId, equals: season.id)
                    // The focusable gate's wrapper holds the real focus, so
                    // the glass button never shows its system focus effect —
                    // draw our own: a focus ring and a slight lift.
                    .overlay {
                        if focusedSeasonId == season.id {
                            Capsule()
                                .stroke(theme.accent, lineWidth: 3)
                        }
                    }
                    .animation(theme.animation, value: focusedSeasonId)
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

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
/// the anchor row starts hidden — its reveal is driven by the owner's scroll
/// progress (`showsSeasonAnchors`), which is 0 while the hero owns the screen.
/// Hidden means unfocusable (opacity-0 controls can't take focus on tvOS, and
/// the row only becomes a focus section once revealed), so the engine's first
/// press down from the hero can't dead-end on the pills; the region entry is
/// steered programmatically onto the parked episode via `isRegionFocused`. Once
/// the scroll commits to the shelves the anchors fade/slide in. Entering the
/// pill row from outside is redirected to the *active* season's pill rather than
/// the geometrically nearest one, and re-focusing the active pill doesn't
/// re-anchor the shelf.
///
/// Renders nothing while the series' seasons haven't loaded, so the call site
/// can mount it unconditionally.
struct EpisodesSection: View {
    @Environment(\.theme) private var theme

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
    /// Whether the season-anchor row is revealed, driven by the owner's scroll
    /// progress (hidden while the hero owns the screen, faded in once the scroll
    /// commits to the shelves). While hidden the row is unfocusable, so the
    /// focus engine's first press down from the hero flows past it to the parked
    /// episode instead of dead-ending on the pills.
    let showsSeasonAnchors: Bool
    /// Long-press menu handlers per episode (view details / watched /
    /// favorite), built by the owner. Episode cards play on select, so the
    /// menu is the only path from here to an episode's own detail page.
    let menu: (MediaItem) -> ShelfMenuHandlers
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

    /// Where the shelf is parked, as an episode index — moved by anchor jumps
    /// and by focus travelling through the shelf. The origin for
    /// `scrollToSeason`'s animate-or-cut test.
    @State private var shelfIndex = 0

    /// `episodeId → index` and `seasonId → first episode index`, rebuilt only
    /// when the series' episode list changes, so a focus move resolves its
    /// season in O(1) instead of scanning the whole series (#115).
    @State private var lookups = EpisodeLookups()

    /// How long a pill must hold focus before the shelf anchors to it —
    /// traversing the pill row shouldn't fire a jump per pill passed through.
    private static let anchorDebounce: Duration = .milliseconds(250)

    /// How far an anchor jump may travel with its real cards still on.
    ///
    /// Every jump animates — the slide *is* the interaction, and cutting reads
    /// as a glitch. What costs is that an animated `scrollTo` makes the lazy
    /// stack *traverse* the gap, mounting and discarding every card it sweeps
    /// past: the biggest recurring hitch on a season-heavy series detail
    /// (#115). Past this distance the shelf ghosts for the length of the slide,
    /// so the traversal mounts rounded rectangles instead — which is exactly
    /// what Apple TV's episode shelf shows mid-jump, hydrating on settle the
    /// same way.
    ///
    /// Under it the slide is short enough that the cards going by are worth
    /// looking at, and mounting a handful costs about what an ordinary scroll
    /// does. Dial to 0 to ghost every jump, or past the longest season to ghost
    /// none.
    private static let maxHydratedJumpCards = 12

    /// Whether the shelf is showing real cards. Cleared for the length of a
    /// long anchor jump (see `maxHydratedJumpCards`).
    @State private var isHydrated = true

    /// Pending re-hydration, timed to the jump's settle.
    @State private var hydrateTask: Task<Void, Never>?

    /// The episode a ghosted jump is flying toward, and the redirect target for
    /// focus that enters the shelf before it lands (see
    /// `onChange(of: focusedEpisodeId)`). Nil whenever no jump is in flight.
    @State private var jumpTargetEpisodeId: String?

    /// Episode card width, owned here because the anchor scrolls are computed
    /// geometrically from it (index × (width + gap)) — id-based scrolls need
    /// `scrollTargetLayout`, which hijacks Siri Remote pans on hardware and
    /// can't resolve cards the lazy stack hasn't built.
    private static let episodeCardWidth: CGFloat = 440

    /// Live shelf geometry for the anchor math (leading inset, the container
    /// width that sizes the trailing runway, and the hydrated row height the
    /// ghosts hold).
    @State private var shelfGeometry = ShelfGeometry(containerWidth: 0, leadingInset: 0, contentHeight: 0)

    /// The season the pills highlight: whichever the shelf is in, falling back
    /// to the first before focus has ever entered.
    private var activeSeasonId: String? {
        currentSeasonId ?? seasons.first?.id
    }

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
                        if showsSeasonAnchors {
                            seasonAnchors.focusSection()
                        } else {
                            seasonAnchors
                        }
                    #else
                        seasonAnchors
                    #endif
                }
                .opacity(showsSeasonAnchors ? 1 : 0)
                .offset(y: showsSeasonAnchors ? 0 : SpacingTokens.md)
                .animation(theme.animation, value: showsSeasonAnchors)

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
            // Follow the scroll: an episode gaining focus hands its season the
            // accent (in either direction). The anchor row's reveal is driven by
            // the owner's scroll progress (`showsSeasonAnchors`), not by focus.
            .onChange(of: focusedEpisodeId) { _, episodeId in
                guard let episodeId, let index = lookups.index(ofEpisode: episodeId) else { return }
                // Focus reaching a card mid-jump means the user pressed into
                // the shelf rather than waiting the slide out. The jump is
                // over — put the real cards back under them now rather than at
                // a settle they've already overtaken.
                if !isHydrated {
                    hydrateTask?.cancel()
                    isHydrated = true
                    // ...and take the landing back off the focus engine, which
                    // resolves against the scroll's *final* layout rather than
                    // the frame on screen. Left alone it picks a card that
                    // isn't visible and then can't reveal it, because our
                    // animation owns the offset — focus sits off screen until a
                    // left/right press shakes it loose. The season the user
                    // asked for is the honest destination anyway.
                    // (Apple TV's own shelf has this same landing bug.)
                    if let target = jumpTargetEpisodeId, target != episodeId {
                        jumpTargetEpisodeId = nil
                        focusedEpisodeId = target
                        return
                    }
                }
                jumpTargetEpisodeId = nil
                // Focus travelling through the shelf is also how the shelf's
                // resting position is tracked, since the cards it lands on are
                // the ones on screen.
                shelfIndex = index
                if let seasonId = episodes[index].seasonId {
                    currentSeasonId = seasonId
                }
            }
            // Rebuilt only when the list itself changes, not per focus move.
            .onChange(of: episodes, initial: true) { _, newEpisodes in
                lookups = EpisodeLookups(newEpisodes)
            }
            // First entry into the below-fold region: steer focus onto the
            // parked episode. Without this the engine sometimes targets the
            // (empty, hidden) pill row's space or skips to the cast shelf.
            // Post-reveal entries are left to the engine — the pills are
            // focusable by then and intercept on purpose.
            .onChange(of: isRegionFocused) { _, entered in
                guard entered, !showsSeasonAnchors, focusedEpisodeId == nil else { return }
                focusedEpisodeId = initialEpisodeId
            }
            // Pre-park the shelf on the most relevant episode (unanimated —
            // this is setup, not a transition) so the focus engine's first
            // entry finds it at the leading edge. Skipped once the user is
            // actually in the shelf.
            .task(id: initialEpisodeId) {
                guard let initialEpisodeId,
                      focusedEpisodeId == nil, !showsSeasonAnchors,
                      // Scanned, not looked up: this fires once at page setup,
                      // before `lookups` is guaranteed populated.
                      let index = episodes.firstIndex(where: { $0.id == initialEpisodeId })
                else { return }
                currentSeasonId = episodes[index].seasonId
                parkShelf(atEpisodeIndex: index)
            }
        }
    }

    private var seasonAnchors: some View {
        ScrollViewReader { pills in
            seasonAnchorRow
                // Keep the active pill on screen. From outside the row only that
                // pill is focusable, so once the shelf scrolls into a season
                // whose pill sits beyond the row's right edge, pressing up has
                // nothing focusable to land on and focus escapes to the hero —
                // a dead end on any series with more seasons than fit (a
                // 17-season show shows nine). Following the shelf here means
                // the one focusable pill is always reachable.
                //
                // `initial: true` covers the first paint too: the shelf
                // pre-parks on next-up, which is usually the *last* season.
                .onChange(of: activeSeasonId, initial: true) { _, seasonId in
                    guard let seasonId else { return }
                    withAnimation(theme.animation) {
                        pills.scrollTo(seasonId, anchor: .center)
                    }
                }
        }
    }

    /// Safe to scroll by id, unlike the episode shelf: the pills are a plain
    /// `HStack`, so every one of them is built and resolvable by the proxy.
    private var seasonAnchorRow: some View {
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
                            .jsStyle(.title)
                            .foregroundStyle(
                                season.id == activeSeasonId ? theme.accent : theme.primary,
                            )
                    }
                    // Inert on purpose: this pill's focus treatment is the ring
                    // overlay below, so the button owes us the resting capsule
                    // and nothing else.
                    //
                    // `glassButtonStyle(tint:)` presented focus on its own and
                    // then kept it — a press left a platter behind, one per
                    // pill pressed. Clicking a pill anchors the shelf, which
                    // changes the active season, which changes every pill's
                    // `.focusable` argument below and rebuilds the button
                    // mid-press: the style never sees the interaction end.
                    // Which platter got stuck depended on the theme — Standard
                    // leaves `focusFill` nil and so drew the system glass
                    // style's white one, the other four themes tint their own.
                    .inertGlassButtonStyle()
                    // From outside the row, only the active season's pill can
                    // take focus — entry always lands on the right pill with
                    // no visible redirect. Inside the row every pill is
                    // focusable so swiping works normally. The `focused`
                    // binding sits OUTSIDE the gate: `.focusable` interposes
                    // its own focus node, and binding inside it never fires —
                    // which would leave the gate stuck shut.
                    .focusable(focusedSeasonId != nil || season.id == activeSeasonId)
                    .focused($focusedSeasonId, equals: season.id)
                    // The focusable gate's wrapper holds the real focus, so the
                    // button underneath can't present focus for us — draw our
                    // own ring.
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
            // `.equatable()` is load-bearing, not decoration — see
            // ``EpisodeShelfStack``. Everything this body reads (the season
            // accent, the anchor reveal, focus) leaves the cards alone.
            EpisodeShelfStack(
                episodes: episodes,
                cardWidth: Self.episodeCardWidth,
                containerWidth: shelfGeometry.containerWidth,
                isHydrated: isHydrated,
                ghostHeight: shelfGeometry.contentHeight,
                menu: menu,
                focusedEpisodeId: $focusedEpisodeId,
                playbackItem: $playbackItem,
            )
            .equatable()
        }
        .scrollPosition($shelfPosition)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: ShelfGeometry.self) { geometry in
            ShelfGeometry(
                containerWidth: geometry.containerSize.width,
                leadingInset: geometry.contentInsets.leading,
                contentHeight: geometry.contentSize.height,
            )
        } action: { _, geometry in
            var next = geometry
            // The ghosts are sized *from* this height, so recording theirs would
            // ratchet the row shorter with every jump. Only the hydrated row
            // gets a vote.
            if !isHydrated {
                next.contentHeight = shelfGeometry.contentHeight
            }
            shelfGeometry = next
        }
    }

    /// Anchor the shelf to a season's first episode. Always animated; a long
    /// jump ghosts its cards for the length of the slide so the traversal stays
    /// cheap (see `maxHydratedJumpCards`), then hydrates on settle.
    private func scrollToSeason(_ seasonId: String) {
        guard let index = lookups.firstIndex(ofSeason: seasonId) else { return }
        currentSeasonId = seasonId

        hydrateTask?.cancel()
        let ghosts = abs(index - shelfIndex) > Self.maxHydratedJumpCards
        if ghosts {
            isHydrated = false
            jumpTargetEpisodeId = episodes[index].id
        }

        withAnimation(theme.animation) {
            parkShelf(atEpisodeIndex: index)
        }

        guard ghosts else { return }
        hydrateTask = Task {
            // Hydrate as the slide lands, not before: swapping mid-flight would
            // put the real cards back under the traversal this exists to spare.
            try? await Task.sleep(for: .seconds(theme.transitionDuration))
            guard !Task.isCancelled else { return }
            isHydrated = true
            jumpTargetEpisodeId = nil
        }
    }

    /// Scroll so the episode at `index` sits on the shelf's screen-padding
    /// boundary — aligned with the cast shelf and the season pills. Pure
    /// arithmetic — cards are fixed-width — so it's exact regardless of how
    /// deep the target is or what the lazy stack has built.
    ///
    /// The offset is exactly "index cards' worth of content": scrolling that
    /// far leaves the stack's leading padding on screen, which is what keeps
    /// the parked card on the same margin as every other section. (Adding the
    /// padding to the offset parks a padding too far left; subtracting the
    /// leading safe-area inset parks an inset too far right.)
    private func parkShelf(atEpisodeIndex index: Int) {
        let x = CGFloat(index) * (Self.episodeCardWidth + SpacingTokens.cardGap)
        shelfIndex = index
        shelfPosition.scrollTo(x: max(0, x))
    }
}

/// Live shelf geometry captured for the anchor math.
private struct ShelfGeometry: Equatable {
    var containerWidth: CGFloat
    var leadingInset: CGFloat
    /// The row's height with real cards in it — held while ghosting.
    var contentHeight: CGFloat
}

/// Index lookups over a series' episode list, built once per list rather than
/// scanned per event: the shelf resolves an episode's season and position on
/// every focus move, and an anchor jump resolves a season's first episode.
private struct EpisodeLookups {
    private var indexByEpisodeId: [String: Int] = [:]
    private var firstIndexBySeasonId: [String: Int] = [:]

    init() {}

    init(_ episodes: [MediaItem]) {
        indexByEpisodeId.reserveCapacity(episodes.count)
        for (index, episode) in episodes.enumerated() {
            indexByEpisodeId[episode.id] = index
            // Episodes arrive in series order, so the first sighting of a
            // season is its first episode.
            if let seasonId = episode.seasonId, firstIndexBySeasonId[seasonId] == nil {
                firstIndexBySeasonId[seasonId] = index
            }
        }
    }

    func index(ofEpisode episodeId: String) -> Int? {
        indexByEpisodeId[episodeId]
    }

    func firstIndex(ofSeason seasonId: String) -> Int? {
        firstIndexBySeasonId[seasonId]
    }
}

import DesignSystem
import JellyfinKit
import SwiftUI

/// The episode cards of a horizontal episode shelf, split out of the sections
/// that host them (``EpisodesSection``, ``SeasonEpisodesSection``) so they form
/// an invalidation boundary.
///
/// Both hosts re-run their body constantly for reasons the cards don't care
/// about: `@FocusState` flips on every focus move, the season accent follows the
/// focused episode, the anchor row reveals on the page's scroll progress, and
/// the owning detail page writes its own scroll state per frame while the page
/// scrolls vertically. Built inline, each of those re-diffed `ForEach` across
/// *every episode in the series* and rebuilt a `menu(episode)` closure per card
/// — 50–80ms per flip on a season-heavy series (#115).
///
/// `.equatable()` at the call site is what makes the boundary real. Without it
/// the `menu` closure alone would defeat it: a fresh closure every render is
/// never equal to the last, so SwiftUI would have to assume the view changed.
///
/// Unlike the library grid's boundary (e73bc2e), the guarded event here is
/// *focus movement*, which fires constantly — not page appends, which fire a
/// handful of times per session.
struct EpisodeShelfStack: View, Equatable {
    @Environment(AppSession.self) private var session

    /// The episodes to render, in shelf order
    let episodes: [MediaItem]
    /// Fixed card width — the hosts compute their parking arithmetic from the
    /// same number, so it can't be measured here.
    let cardWidth: CGFloat
    /// The shelf's container width, for the trailing runway
    let containerWidth: CGFloat
    /// Whether to render real cards. `false` swaps in ghosts for the length of
    /// a long anchor jump, so the lazy stack's traversal mounts rounded
    /// rectangles instead of artwork, text and glass (#115).
    var isHydrated = true
    /// The hydrated row's measured height, held while ghosting so the sections
    /// below don't shift as the cards thin out. Ignored when hydrated, where
    /// the real cards size the row.
    var ghostHeight: CGFloat = 0
    /// Long-press menu handlers per episode, built by the host
    let menu: (MediaItem) -> ShelfMenuHandlers
    /// Which episode card owns focus; owned by the host, which drives its
    /// season accent and first-focus steering from it.
    @FocusState.Binding var focusedEpisodeId: String?
    /// Clicking a card plays it immediately via the host's player
    @Binding var playbackItem: MediaItem?

    var body: some View {
        LazyHStack(alignment: .top, spacing: SpacingTokens.cardGap) {
            ForEach(episodes) { episode in
                if isHydrated {
                    episode.episodeShelfItem(
                        client: session.client,
                        width: cardWidth,
                        menu: menu(episode),
                    ) {
                        playbackItem = episode
                    }
                    .focused($focusedEpisodeId, equals: episode.id)
                } else {
                    // Focusable, unlike the load-time skeletons this borrows
                    // its shapes from. Those sit on a screen with nothing else
                    // to focus, so waiting for real content is right. These
                    // don't: the cast shelf is one row down, and an
                    // unfocusable row means a press of Down mid-jump sails
                    // straight past the episodes into it. Carrying the same
                    // `focusedEpisodeId` binding as the real card means focus
                    // survives the swap on the way back.
                    GhostEpisodeCard(width: cardWidth, aspectRatio: Self.stillAspectRatio)
                        .focusable()
                        .focused($focusedEpisodeId, equals: episode.id)
                }
            }
        }
        .padding(.leading, SpacingTokens.screenPadding)
        // Trailing runway: enough room past the last card that a late season's
        // first episode can still park at the far left — without it, anchoring
        // an ongoing season with a couple of episodes clamps short.
        .padding(.trailing, max(
            SpacingTokens.screenPadding,
            containerWidth - cardWidth - SpacingTokens.screenPadding,
        ))
        .padding(.vertical, SpacingTokens.focusPadding)
        // Ghosts are a bare artwork frame and one caption bar, far shorter than
        // a real card's two captions and six-line synopsis. Holding the hydrated
        // height keeps the cast and similar shelves still through the jump.
        .frame(minHeight: isHydrated ? nil : ghostHeight, alignment: .top)
    }

    /// Episode stills are 16:9, and the ghosts have to match or the row's
    /// artwork line shifts as they swap in.
    private static let stillAspectRatio: CGFloat = 16.0 / 9.0

    /// Compares only what the cards actually render from. `episodes` is the
    /// host's own array, so the common case hits `Array`'s buffer-identity fast
    /// path and costs nothing — while a real change (a user-data toggle marking
    /// an episode watched) still compares unequal and rebuilds.
    ///
    /// The closure and bindings are excluded deliberately: `menu` is rebuilt on
    /// every host render and would defeat the boundary outright, and the
    /// bindings are stable handles into the host's storage, not values.
    /// `nonisolated` because `Equatable` is: conforming to `View` infers
    /// main-actor isolation for the whole type, which an `Equatable` witness
    /// can't inherit. Safe here because every field it touches is an immutable
    /// `Sendable` value — the closure and bindings that aren't are also the
    /// ones it deliberately ignores.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episodes == rhs.episodes
            && lhs.cardWidth == rhs.cardWidth
            && lhs.containerWidth == rhs.containerWidth
            && lhs.isHydrated == rhs.isHydrated
            && lhs.ghostHeight == rhs.ghostHeight
    }
}

/// A ghost of one episode card's lockup: the still, the "S1E3" eyebrow, the
/// episode title, and the block of synopsis the real card reserves six lines
/// for. A bare artwork frame reads as an *empty* shelf; this reads as one that
/// hasn't caught up yet.
///
/// Composed from ``GhostBlock`` rather than extending ``GhostCard``, which is
/// the poster/still lockup other shelves ghost with — an episode card is the
/// only one carrying a synopsis, and the skeleton vocabulary is explicitly a
/// set of primitives for screens to build their own shapes from.
///
/// Deliberately approximate. The real captions are theme fonts arranged by the
/// tvOS borderless lockup, whose spacing isn't ours to read, so these bars are
/// sized from the type scale and can't land on the exact same height. Holding
/// the row's measured height is what actually keeps the page still (see
/// ``EpisodeShelfStack/ghostHeight``); this only has to *look* like an episode.
private struct GhostEpisodeCard: View {
    let width: CGFloat
    let aspectRatio: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            GhostBlock(width: width, height: width / aspectRatio)

            // Eyebrow over title, matching the episode card's flipped captions.
            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                GhostBlock(width: width * 0.2, height: Self.bar(TypographyTokens.Size.body))
                GhostBlock(
                    width: width * 0.85,
                    height: Self.bar(TypographyTokens.Size.title, emphasized: true),
                )
            }

            // Leading, not the caption gap: paragraph lines sit closer to each
            // other than the blocks around them. The last runs short, the way a
            // wrapped final line does.
            VStack(alignment: .leading, spacing: Self.synopsisLineGap) {
                ForEach(0 ..< Self.synopsisLines, id: \.self) { line in
                    GhostBlock(
                        width: line == Self.synopsisLines - 1 ? width * 0.55 : width,
                        height: Self.bar(TypographyTokens.Size.body),
                    )
                }
            }
        }
    }

    /// A bar standing in for one line of text at `size`. Rendered ink is well
    /// under the nominal point size — a bar at the full size reads as a slab,
    /// not a line of prose.
    /// Emphasized roles (the semibold episode title) put down heavier strokes
    /// and read taller at the same nominal size.
    private static func bar(_ size: CGFloat, emphasized: Bool = false) -> CGFloat {
        (size * (emphasized ? 0.72 : 0.62)).rounded()
    }

    /// The leftover of a body line's height once its bar is drawn, so the
    /// paragraph's rhythm matches real text set at the same size.
    private static let synopsisLineGap =
        (TypographyTokens.Size.body * TypographyTokens.LineHeight.normal
            - bar(TypographyTokens.Size.body)).rounded()

    /// Matches the episode card's `lineLimit(6, reservesSpace: true)`.
    private static let synopsisLines = 6
}

#Preview("Ghost episode row") {
    ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: SpacingTokens.cardGap) {
            ForEach(0 ..< 4, id: \.self) { _ in
                GhostEpisodeCard(width: 440, aspectRatio: 16.0 / 9.0)
            }
        }
        .padding(SpacingTokens.screenPadding)
    }
    .withThemeEnvironment()
}

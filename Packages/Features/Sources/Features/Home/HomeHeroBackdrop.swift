import DesignSystem
import JellyfinKit
import SwiftUI

/// Full-bleed backdrop for the Home hero carousel.
///
/// Mounted in the scroll view's `.background` (an in-flow view can't escape
/// the safe area), but offset by the live scroll position so it rides the
/// content — the hero and its backdrop slide up together as one unit instead
/// of the backdrop sitting fixed behind the shelves.
///
/// Paging is the marquee's one visible motion (the foreground fades, per
/// `HomeHeroSection`): the incoming image slides in from the turn's direction
/// *over* the outgoing one, which holds still and fades underneath — the
/// screen is always covered, so no background bleeds at the edges. It doesn't
/// try to track the tab view's interactive slide (syncing to it is what made
/// earlier rounds lag); it's the backdrop's own settle, timed by the theme.
struct HomeHeroBackdrop: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let url: URL?
    let blurHash: String?
    /// Paging identity: a new id slides the next backdrop in.
    let itemId: String
    /// Which edge the incoming image enters from.
    let direction: HomeViewModel.PagingDirection
    /// Monotonic turn counter — stacks the incoming image above the outgoing
    /// one (item ids can't order a wrap from the last page back to the first).
    let generation: Int
    /// Live scroll offset (`contentOffset.y + contentInsets.top`).
    let scrollOffset: CGFloat
    /// Hero exit progress (0 at rest, 1 once the shelves own the screen);
    /// the backdrop fades out as it slides up, and back in on the way down.
    let progress: CGFloat

    var body: some View {
        ZStack {
            ArtworkImage(url: url, blurHash: blurHash)
                .frame(height: HomeHeroMotion.backdropHeight)
                .frame(maxWidth: .infinity)
                .id(itemId)
                .zIndex(Double(generation))
                .transition(.asymmetric(
                    insertion: .move(edge: direction == .forward ? .trailing : .leading),
                    // Hold the outgoing image opaque until the incoming
                    // slide has covered it, then release — fading it on the
                    // shared clock exposed a dark band at the uncovered edge.
                    removal: .opacity.animation(
                        .linear(duration: HomeHeroMotion.backdropOutgoingFadeDuration)
                            .delay(HomeHeroMotion.backdropOutgoingHold),
                    ),
                ))
        }
        .animation(reduceMotion ? nil : theme.animation, value: itemId)
        // Scrim rides above the image but outside the paging key, so it holds
        // steady while pages slide beneath it.
        .overlay { leadingScrim }
        .mask { bottomFade }
        .opacity(1 - progress)
        .offset(y: -scrollOffset)
        .ignoresSafeArea()
    }

    /// Keeps the left-stacked lockup legible over bright artwork.
    private var leadingScrim: some View {
        LinearGradient(
            stops: [
                .init(color: theme.background.opacity(HomeHeroMotion.scrimEdgeOpacity), location: 0.0),
                .init(color: .clear, location: HomeHeroMotion.scrimEnd),
            ],
            startPoint: .leading,
            endPoint: .trailing,
        )
    }

    /// Fades the backdrop out above the shelves (no melt treatment — the
    /// image simply ends before the content does).
    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: HomeHeroMotion.backdropFadeStart),
                .init(color: .clear, location: HomeHeroMotion.backdropFadeEnd),
            ],
            startPoint: .top,
            endPoint: .bottom,
        )
    }
}

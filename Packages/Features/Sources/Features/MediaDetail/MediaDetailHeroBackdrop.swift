import DesignSystem
import SwiftUI

/// Full-bleed backdrop behind the above-the-fold content. Masked with a
/// gradient so it melts into the background. Rather than disappearing once the
/// hero scrolls away, it stays mounted and dims + blurs into a faint
/// atmospheric wash behind the shelves as `progress` ramps from 0 to 1.
struct MediaDetailHeroBackdrop: View {
    @Environment(\.theme) private var theme

    let url: URL
    /// Continuous scroll progress: 0 at the top, 1 once the hero has fully
    /// transitioned to its dimmed, blurred wash. Already clamped by the caller.
    let progress: CGFloat

    var body: some View {
        ArtworkImage(url: url)
            .overlay {
                // Bottom-edge "melt", above the fold only (fades out on scroll
                // so the below-fold state is purely the dim + blur wash that
                // matches `OverviewOverlay`):
                //   1. a frosted `.ultraThinMaterial`, masked by a gradient so
                //      it only frosts the lower portion of the backdrop;
                //   2. a gradient of the page background color on top, so the
                //      backdrop fades cleanly into the surface beneath the hero
                //      text — solid at the bottom edge, clearing toward the
                //      middle.
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black.opacity(0.3), location: 0.3),
                                    .init(color: .black.opacity(0), location: 0.6)
                                ],
                                startPoint: .bottom, endPoint: .top
                            )
                        }
                    LinearGradient(
                        stops: [
                            .init(color: theme.background, location: 0.0),
                            .init(color: theme.background.opacity(0.6), location: 0.3),
                            .init(color: theme.background.opacity(0), location: 0.6)
                        ],
                        startPoint: .bottom, endPoint: .top
                    )
                }
                .opacity(1 - progress)
            }
            // ── Scroll-transition tuning ─────────────────────────────────
            // All three effects are driven by `progress` (0 at top → 1 after
            // scrolling `heroFadeDistance` pts). Adjust the speed of the whole
            // transition with `heroFadeDistance` (declared in MediaDetailView);
            // tune the *destination* look of each effect here:
            //
            //   • Melt overlay: `1 - progress` fades the above-fold
            //     gradient/frost out completely. Multiply by < 1 to leave some
            //     melt behind even when fully scrolled.
            //   • Backdrop dim: `0.7` is how much it dims — final opacity is
            //     1 − 0.7 = 0.3. Larger factor = darker wash (e.g. 0.85 → 0.15
            //     remaining); smaller = brighter backdrop while scrolled.
            //   • Blur: `20` is the max blur radius at full scroll. Higher =
            //     softer/foggier wash; 0 disables the blur entirely.
            // ─────────────────────────────────────────────────────────────
            .opacity(1 - 0.85 * progress)
            .blur(radius: 20 * progress)
            .ignoresSafeArea()
    }
}

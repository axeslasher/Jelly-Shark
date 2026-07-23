import SwiftUI

// The app-wide skeleton vocabulary: theme-surface ghost shapes that mirror a
// screen's real layout while its first load is in flight.
//
// Every screen builds its loading state from these primitives so "content not
// here yet" looks the same everywhere — ghosts sit exactly where the loaded
// layout will (no jump on handoff), pulse gently via ``skeletonPulse()``
// (static under Reduce Motion), and are plain shapes, never focusable, so
// tvOS focus waits on real content instead of landing on a placeholder.

/// A rounded theme-surface rectangle standing in for a block of content — a
/// text line, a lockup, an artwork frame.
public struct GhostBlock: View {
    @Environment(\.theme) private var theme

    private let width: CGFloat
    private let height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius)
            .fill(theme.surface)
            .frame(width: width, height: height)
    }
}

/// A ghost of a shelf/grid card lockup: an artwork frame with a caption
/// stand-in beneath, so ghost rows and grids read as rows of cards.
///
/// Fixed-width in shelves (cards own their size there); width-less in
/// adaptive grids, where the card fills its cell — sizing must come from
/// the layout pass itself, never a measured width (see the adaptive-grid
/// note on `SkeletonShelf`'s sibling usage in Library).
public struct GhostCard: View {
    @Environment(\.theme) private var theme

    private let width: CGFloat?
    private let aspectRatio: CGFloat

    public init(width: CGFloat? = nil, aspectRatio: CGFloat) {
        self.width = width
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        VStack(alignment: .center, spacing: SpacingTokens.xs) {
            if let width {
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(theme.surface)
                    .frame(width: width, height: width / aspectRatio)
            } else {
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(theme.surface)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }

            // The flexible card's caption is a fixed stand-in width (roughly
            // 60% of a typical poster cell) — a proportional width would need
            // its own measurement, which is exactly what the flexible card
            // exists to avoid.
            GhostBlock(width: width.map { $0 * 0.6 } ?? 150, height: 18)
        }
    }
}

/// A ghost of one ``ContentShelf``: a header stand-in over a horizontal row
/// of ghost cards, with the shelf's exact paddings so the real shelf lands in
/// the same place.
public struct SkeletonShelf: View {
    /// The shape of the row's cards: rounded artwork frames (posters,
    /// stills) or circles (cast headshots).
    public enum CardShape {
        case artwork(aspectRatio: CGFloat)
        case circle
    }

    @Environment(\.theme) private var theme

    private let cardWidth: CGFloat
    private let shape: CardShape
    private let cardCount: Int
    private let showsHeader: Bool

    public init(
        cardWidth: CGFloat,
        shape: CardShape,
        cardCount: Int = 8,
        showsHeader: Bool = true,
    ) {
        self.cardWidth = cardWidth
        self.shape = shape
        self.cardCount = cardCount
        self.showsHeader = showsHeader
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            if showsHeader {
                GhostBlock(width: 280, height: 30)
                    .padding(.horizontal, SpacingTokens.screenPadding)
            }

            // The cards live in their own horizontal scroll, exactly like
            // `ContentShelf` — NOT a naked HStack: rows overflow the screen on
            // purpose, and overflowing content inside a vertical scroll
            // re-centers the whole content stack horizontally, throwing every
            // narrower sibling off-screen left. The scroll contains the
            // overflow.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                    ForEach(0 ..< cardCount, id: \.self) { _ in
                        card
                    }
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
                .padding(.vertical, SpacingTokens.focusPadding)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch shape {
        case let .artwork(aspectRatio):
            GhostCard(width: cardWidth, aspectRatio: aspectRatio)
        case .circle:
            VStack(alignment: .center, spacing: SpacingTokens.xs) {
                Circle()
                    .fill(theme.surface)
                    .frame(width: cardWidth, height: cardWidth)

                GhostBlock(width: cardWidth * 0.6, height: 18)
            }
        }
    }
}

public extension View {
    /// The shared skeleton pulse: a gentle opacity breathe while the skeleton
    /// is on screen, static under Reduce Motion. Apply once to a screen's
    /// whole skeleton container — not per ghost — so everything breathes in
    /// unison, and VoiceOver reads the container as "Loading".
    func skeletonPulse() -> some View {
        modifier(SkeletonPulseModifier())
    }
}

private struct SkeletonPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.55 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: pulsing,
            )
            .onAppear { pulsing = true }
            .accessibilityLabel("Loading")
    }
}

#Preview("Skeleton shelves") {
    ScrollView {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            SkeletonShelf(cardWidth: 440, shape: .artwork(aspectRatio: 16.0 / 9.0), cardCount: 4)
            SkeletonShelf(cardWidth: 200, shape: .artwork(aspectRatio: 2.0 / 3.0))
            SkeletonShelf(cardWidth: 200, shape: .circle)
        }
        .skeletonPulse()
    }
    .withThemeEnvironment()
}

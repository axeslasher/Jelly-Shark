import DesignSystem
import SwiftUI

/// First-load stand-in for Home: a hero-shaped ghost and two skeleton
/// shelves. Nothing here is focusable, so tvOS focus waits on real content
/// (or the tab bar) instead of landing on a placeholder.
struct HomeSkeleton: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulsing = false

    var body: some View {
        // Mirrors the real content's scroll structure (same container, same
        // spine, same paddings) so the ghosts sit exactly where the loaded
        // layout will — a plain stack gets inset differently than scroll
        // content, which read as mismatched screen padding.
        ScrollView {
            // Hero → first shelf uses the tighter hero gap (the peeking
            // Continue Watching row hugs the hero); shelves keep the
            // section stride between themselves — same as the real spine.
            VStack(alignment: .leading, spacing: HomeHeroMotion.heroToShelvesGap) {
                heroGhost

                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    // The peeking row is headerless while the hero owns the
                    // screen, so its ghost is too.
                    skeletonShelf(aspectRatio: 16.0 / 9.0, cardWidth: 440, showsHeader: false)
                    skeletonShelf(
                        aspectRatio: 2.0 / 3.0,
                        cardWidth: PosterGridLayout.minimumCardWidth,
                    )
                }
            }
            .padding(.bottom, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .opacity(pulsing ? 0.55 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
            value: pulsing,
        )
        .onAppear { pulsing = true }
        .accessibilityLabel("Loading")
    }

    /// Ghost of the hero lockup, line for line: logo, the fact-row/overview
    /// pair, the year/genre caption, then the controls row — bottom-anchored
    /// with the real page's clearance, so nothing jumps when content fades in.
    private var heroGhost: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            ghostBlock(width: 360, height: 120)

            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                ghostBlock(width: 320, height: 26)
                ghostBlock(width: HomeHeroMotion.overviewMaxWidth, height: 72)
            }

            ghostBlock(width: 240, height: 20)
            ghostBlock(width: 320, height: 56)
        }
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, HomeHeroMotion.controlsBottomClearance)
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
            height * HomeHeroMotion.heroHeightFraction
        }
    }

    /// One ghost row. The cards live in their own horizontal scroll, exactly
    /// like `ContentShelf` — NOT a naked HStack: rows overflow the screen on
    /// purpose, and overflowing content inside the vertical scroll re-centers
    /// the whole content stack horizontally, throwing every narrower sibling
    /// (the hero ghost) off-screen left. The scroll contains the overflow.
    private func skeletonShelf(
        aspectRatio: CGFloat,
        cardWidth: CGFloat,
        showsHeader: Bool = true,
    ) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            if showsHeader {
                ghostBlock(width: 280, height: 30)
                    .padding(.horizontal, SpacingTokens.screenPadding)
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                    ForEach(0 ..< 8, id: \.self) { _ in
                        VStack(alignment: .center, spacing: SpacingTokens.xs) {
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .fill(theme.surface)
                                .frame(width: cardWidth, height: cardWidth / aspectRatio)
                            // Caption stand-in, so cards read as lockups.
                            ghostBlock(width: cardWidth * 0.6, height: 18)
                        }
                    }
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }

    private func ghostBlock(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius)
            .fill(theme.surface)
            .frame(width: width, height: height)
    }
}

#Preview("Skeleton") {
    HomeSkeleton()
        .withThemeEnvironment()
}

/// Deliberate hero-shaped empty state: connected-but-empty servers get a
/// nudge to add media; disconnected sessions get pointed at Settings. The
/// Settings button doubles as the page's focus anchor — with nothing else
/// focusable, the tvOS focus engine strands the user (the collapsed sidebar
/// can't take focus either, #69).
struct HomeEmptyState: View {
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    let isConnected: Bool
    let userName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            Image(systemName: "film.fill")
                .font(.system(size: 64))
                .foregroundStyle(theme.secondary)

            Text(isConnected ? "Nothing here yet" : "Welcome to Jelly Shark")
                .jsStyle(.display)
                .foregroundStyle(theme.primary)

            Text(subtitle)
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: HomeHeroMotion.overviewMaxWidth, alignment: .leading)

            if let openSettings {
                Button {
                    openSettings()
                } label: {
                    HStack(spacing: SpacingTokens.sm) {
                        Image(systemName: "gear")
                        Text(isConnected ? "Open Settings" : "Connect in Settings")
                    }
                    .jsStyle(.headline)
                }
                .glassButtonStyle(tint: theme.focusFill)
                .padding(.top, SpacingTokens.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, SpacingTokens.md)
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
            height * HomeHeroMotion.heroHeightFraction
        }
    }

    private var subtitle: String {
        if isConnected {
            let greeting = userName.map { "Signed in as \($0). " } ?? ""
            return greeting + "Add media to your Jellyfin libraries and it will show up here."
        }
        return "Connect to your Jellyfin server in Settings to see your media."
    }
}

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
            VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                heroGhost
                skeletonShelf(aspectRatio: 16.0 / 9.0, cardWidth: 440)
                skeletonShelf(aspectRatio: 2.0 / 3.0, cardWidth: 200)
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

    /// Ghost of the hero lockup: logo box, overview lines, button row.
    private var heroGhost: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            ghostBlock(width: HomeHeroMotion.logoWidth, height: 120)
            ghostBlock(width: HomeHeroMotion.overviewMaxWidth, height: 72)
            ghostBlock(width: 320, height: 56)
        }
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, SpacingTokens.md)
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
            height * HomeHeroMotion.heroHeightFraction
        }
    }

    private func skeletonShelf(aspectRatio: CGFloat, cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            ghostBlock(width: 280, height: 30)

            HStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                ForEach(0 ..< 6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.surface)
                        .frame(width: cardWidth, height: cardWidth / aspectRatio)
                }
            }
        }
        .padding(.horizontal, SpacingTokens.screenPadding)
    }

    private func ghostBlock(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius)
            .fill(theme.surface)
            .frame(width: width, height: height)
    }
}

/// Deliberate hero-shaped empty state: connected-but-empty servers get a
/// nudge to add media; disconnected sessions get pointed at Settings. (The
/// tab bar remains the focus target — nothing on the page itself needs it.)
struct HomeEmptyState: View {
    @Environment(\.theme) private var theme

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

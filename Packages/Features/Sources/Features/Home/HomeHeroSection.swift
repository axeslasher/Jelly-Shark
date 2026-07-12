import DesignSystem
import JellyfinKit
import SwiftUI

/// The Home marquee's foreground: a left-stacked lockup (logo, overview,
/// metadata) that pages horizontally between the curated items, over a stable
/// row of controls — Play, Details, Next — and page dots.
///
/// The controls stay outside the paged subtree on purpose: their labels change
/// with the item but the focusable nodes persist, so tvOS focus never sits on
/// a view that's mid-removal. Inputs are narrow values so scroll ticks in the
/// owner skip this body.
struct HomeHeroSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let items: [MediaItem]
    let index: Int
    /// What Play starts for the current item — nil disables the button
    /// (still resolving, or a box set).
    let playTarget: MediaItem?
    let onPlay: (MediaItem) -> Void
    let onNext: () -> Void

    private var item: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private var pageAnimation: Animation? {
        reduceMotion ? nil : theme.animation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.lg) {
            if let item {
                ZStack(alignment: .bottomLeading) {
                    lockup(for: item)
                }
                // Full width so the page slide traverses the screen, not just
                // the lockup's own bounds.
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .animation(pageAnimation, value: item.id)

                controls(for: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, SpacingTokens.md)
        // Bottom-anchored fractional hero: the lockup grows upward into the
        // backdrop and the Continue Watching row peeks above the fold (see
        // MediaDetailHeroSection for the anchoring rationale).
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
            height * HomeHeroMotion.heroHeightFraction
        }
        // Page dots hang just below the hero's bottom edge, centered in the
        // hero→shelves gap — an overlay so they never participate in the
        // left stack's layout.
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                pageDots
                    .offset(y: HomeHeroMotion.dotsDrop)
            }
        }
    }

    // MARK: - Paged lockup

    private func lockup(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            titleTreatment(for: item)

            if let overview = item.overview {
                Text(overview)
                    .jsStyle(.body)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: HomeHeroMotion.overviewMaxWidth, alignment: .leading)
            }

            if let metadataLine = metadataLine(for: item) {
                Text(metadataLine)
                    .jsStyle(.caption, .emphasized)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
        }
        .id(item.id)
        .transition(HomeHeroMotion.pageTransition)
    }

    /// Logo lockup with text fallback — the same `TrimmedLogoImage` recipe as
    /// the detail hero (fixed bottom-leading box so content below never shifts).
    @ViewBuilder
    private func titleTreatment(for item: MediaItem) -> some View {
        if let client = session.client, let url = client.logoURL(for: item) {
            TrimmedLogoImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: HomeHeroMotion.logoWidth,
                        height: HomeHeroMotion.logoHeight,
                        alignment: .bottomLeading,
                    )
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
            } fallback: {
                titleText(for: item)
            }
        } else {
            titleText(for: item)
        }
    }

    private func titleText(for item: MediaItem) -> some View {
        Text(item.name)
            .jsStyle(.display)
            .foregroundStyle(theme.primary)
    }

    /// One subdued line: year · up to three genres.
    private func metadataLine(for item: MediaItem) -> String? {
        var parts: [String] = []
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if let genres = item.genres, !genres.isEmpty {
            parts.append(contentsOf: genres.prefix(3))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: - Controls (stable across pages)

    private func controls(for item: MediaItem) -> some View {
        HStack(alignment: .center, spacing: SpacingTokens.sm) {
            playButton

            CircleNavigationLink(
                systemImage: "info",
                title: "Details",
                value: item,
            )

            CircleActionButton(
                systemImage: "arrow.right",
                title: "Next",
                tint: theme.primary,
                isEnabled: items.count > 1,
            ) {
                onNext()
            }
        }
    }

    private var playButton: some View {
        Button {
            if let playTarget {
                onPlay(playTarget)
            }
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: "play.fill")
                Text(playTarget?.hasProgress == true ? "Resume" : "Play")
            }
            .jsStyle(.headline)
        }
        .glassButtonStyle(tint: theme.focusFill)
        .disabled(session.client == nil || playTarget == nil)
    }

    /// Display-only page indicators; paging is driven by the Next button and
    /// the auto-advance timer.
    private var pageDots: some View {
        HStack(spacing: SpacingTokens.xs) {
            ForEach(items.indices, id: \.self) { dotIndex in
                Capsule()
                    .fill(dotIndex == index ? theme.accent : theme.tertiary.opacity(0.4))
                    .frame(
                        width: dotIndex == index ? HomeHeroMotion.activeDotWidth : HomeHeroMotion.dotWidth,
                        height: HomeHeroMotion.dotHeight,
                    )
            }
        }
        .animation(pageAnimation, value: index)
        .accessibilityHidden(true)
    }
}

/// `CircleActionButton`'s value-based-navigation twin: the same circular glass
/// treatment and focus-revealed hanging label, but pushing a destination
/// instead of running an action.
private struct CircleNavigationLink<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    let systemImage: String
    let title: String
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            Image(systemName: systemImage)
                .jsStyle(.headline)
                .foregroundStyle(isFocused ? theme.onFocusFill : theme.primary)
                // Fixed glyph box so every circle renders the same size
                // (matches CircleActionButton).
                .frame(width: 44, height: 44)
        }
        .glassButtonStyle(tint: theme.focusFill, circular: true)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .focused($isFocused)
        .overlay(alignment: .bottom) {
            Text(title)
                .jsStyle(.caption)
                .foregroundStyle(theme.secondary)
                .fixedSize()
                .opacity(isFocused ? 1 : 0)
                .alignmentGuide(.bottom) { $0[.top] - SpacingTokens.sm }
        }
        .animation(theme.animation, value: isFocused)
    }
}

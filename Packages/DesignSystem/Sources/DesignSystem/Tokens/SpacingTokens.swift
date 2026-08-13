import SwiftUI

/// Spacing tokens for consistent layout throughout the app
/// Based on an 8pt grid system, scaled for 10-foot UI and then by
/// `platformScale`. Values below are the tvOS ones.
public enum SpacingTokens {
    // MARK: - Platform Scale

    // ┌────────────────────────────────────────────────────────────────┐
    // │ THIS IS WHERE YOU TUNE visionOS SPACING.                       │
    // └────────────────────────────────────────────────────────────────┘
    //
    // The partner to `TypographyTokens.Size.platformScale`, kept separate
    // because the two don't have to move together: type has a legibility
    // floor, layout has a reachability one. Starting them at the same value
    // keeps the visionOS layout in the same proportion to its type as tvOS's
    // is to its own — shrink the type alone and the whole UI reads as sparse.
    //
    // Note this turns the 8pt grid into a 6pt one at 0.75. That's still a
    // coherent grid (every step stays a whole multiple of 3), but if you tune
    // this, prefer factors that keep `unit` an integer.
    #if os(visionOS)
        public static let platformScale: CGFloat = 0.75
    #else
        public static let platformScale: CGFloat = 1
    #endif

    // MARK: - Base Unit

    /// Base spacing unit (8pt)
    public static let unit: CGFloat = 8 * platformScale

    // MARK: - Fixed Spacing Scale

    /// Extra small spacing (4pt) - tight gaps
    public static let xxs: CGFloat = 4 * platformScale

    /// Extra small spacing (8pt)
    public static let xs: CGFloat = 8 * platformScale

    /// Small spacing (16pt)
    public static let sm: CGFloat = 16 * platformScale

    /// Medium spacing (24pt)
    public static let md: CGFloat = 24 * platformScale

    /// Large spacing (32pt)
    public static let lg: CGFloat = 32 * platformScale

    /// Extra large spacing (48pt)
    public static let xl: CGFloat = 48 * platformScale

    /// Extra extra large spacing (64pt)
    public static let xxl: CGFloat = 64 * platformScale

    /// Huge spacing (96pt)
    public static let huge: CGFloat = 96 * platformScale

    // MARK: - Semantic Spacing

    /// Padding inside cards
    public static let cardPadding: CGFloat = 24 * platformScale

    /// Space between cards in a grid
    public static let cardGap: CGFloat = 32 * platformScale

    /// Padding at screen edges
    public static let screenPadding: CGFloat = 28 * platformScale

    /// Space between sections
    public static let sectionSpacing: CGFloat = 60 * platformScale

    /// Space between a header and its content
    public static let headerSpacing: CGFloat = 8 * platformScale

    // MARK: - Focus Spacing

    // Deliberately unscaled. These pad a control outward, so they feed the
    // hit area rather than the composition — and visionOS targets are aimed
    // with eyes, which wants targets no smaller than tvOS's, not 25% smaller.

    /// Extra padding to accommodate focus ring
    public static let focusPadding: CGFloat = 16

    /// Focus ring inset
    public static let focusInset: CGFloat = 4
}

// MARK: - Convenience Extensions

public extension EdgeInsets {
    /// Uniform padding with spacing token
    static func uniform(_ value: CGFloat) -> EdgeInsets {
        EdgeInsets(top: value, leading: value, bottom: value, trailing: value)
    }

    /// Card padding insets
    static var cardPadding: EdgeInsets {
        .uniform(SpacingTokens.cardPadding)
    }

    /// Screen padding insets
    static var screenPadding: EdgeInsets {
        .uniform(SpacingTokens.screenPadding)
    }
}

#Preview {
    let manager = ThemeManager.preview()
    let theme = manager.currentTheme
    let tokens: [(name: String, value: CGFloat)] = [
        ("xxs", SpacingTokens.xxs),
        ("xs", SpacingTokens.xs),
        ("sm", SpacingTokens.sm),
        ("md", SpacingTokens.md),
        ("lg", SpacingTokens.lg),
        ("xl", SpacingTokens.xl),
        ("xxl", SpacingTokens.xxl),
        ("huge", SpacingTokens.huge),
        ("cardPadding", SpacingTokens.cardPadding),
        ("cardGap", SpacingTokens.cardGap),
        ("screenPadding", SpacingTokens.screenPadding),
        ("sectionSpacing", SpacingTokens.sectionSpacing),
        ("headerSpacing", SpacingTokens.headerSpacing),
        ("focusPadding", SpacingTokens.focusPadding),
        ("focusInset", SpacingTokens.focusInset),
    ]
    ScrollView {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            ForEach(tokens, id: \.name) { entry in
                HStack(spacing: SpacingTokens.md) {
                    Text("\(entry.name) \(Int(entry.value))pt")
                        .jsStyle(.caption)
                        .foregroundStyle(theme.secondary)
                        .frame(width: 280, alignment: .leading)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: max(entry.value, 1), height: 12)
                }
            }
        }
        .padding(SpacingTokens.screenPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(theme.background)
    .withThemeEnvironment(manager)
}

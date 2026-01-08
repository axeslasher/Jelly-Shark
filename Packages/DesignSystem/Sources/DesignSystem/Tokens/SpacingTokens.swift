import SwiftUI

/// Spacing tokens for consistent layout throughout the app
/// Based on an 8pt grid system, scaled for 10-foot UI
public enum SpacingTokens {
    // MARK: - Base Unit

    /// Base spacing unit (8pt)
    public static let unit: CGFloat = 8

    // MARK: - Fixed Spacing Scale

    /// Extra small spacing (4pt) - tight gaps
    public static let xxs: CGFloat = 4

    /// Extra small spacing (8pt)
    public static let xs: CGFloat = 8

    /// Small spacing (16pt)
    public static let sm: CGFloat = 16

    /// Medium spacing (24pt)
    public static let md: CGFloat = 24

    /// Large spacing (32pt)
    public static let lg: CGFloat = 32

    /// Extra large spacing (48pt)
    public static let xl: CGFloat = 48

    /// Extra extra large spacing (64pt)
    public static let xxl: CGFloat = 64

    /// Huge spacing (96pt)
    public static let huge: CGFloat = 96

    // MARK: - Semantic Spacing

    /// Padding inside cards
    public static let cardPadding: CGFloat = 24

    /// Space between cards in a grid
    public static let cardGap: CGFloat = 32

    /// Padding at screen edges
    public static let screenPadding: CGFloat = 48

    /// Space between sections
    public static let sectionSpacing: CGFloat = 64

    /// Space between a header and its content
    public static let headerSpacing: CGFloat = 24

    // MARK: - Focus Spacing

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

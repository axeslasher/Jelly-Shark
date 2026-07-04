import SwiftUI

/// Typography tokens for the design system
public enum TypographyTokens {
    /// Typography scale sizes optimized for 10-foot UI
    public enum Size {
        /// Display text - 52pt (hero titles)
        public static let display: CGFloat = 52

        /// Headline - 32pt (section headers)
        public static let headline: CGFloat = 32

        /// Title - 24pt (card titles)
        public static let title: CGFloat = 24
        
        /// Overview - 24pt (long text descriptions)
        public static let overview: CGFloat = 24

        /// Body - 22pt
        public static let body: CGFloat = 22
        

        /// Caption - 14pt (metadata)
        public static let caption: CGFloat = 18

        /// Small - 12pt (badges, labels)
        public static let small: CGFloat = 12
    }

    /// Font weights
    public enum Weight {
        public static let display: Font.Weight = .bold
        public static let headline: Font.Weight = .semibold
        public static let title: Font.Weight = .semibold
        public static let overview: Font.Weight = .medium
        public static let body: Font.Weight = .regular
        public static let caption: Font.Weight = .regular
    }

    /// Letter spacing (tracking)
    public enum Tracking {
        /// Tight tracking for display text
        public static let tight: CGFloat = -0.5

        /// Normal tracking
        public static let normal: CGFloat = 0

        /// Wide tracking for emphasis
        public static let wide: CGFloat = 0.5

        /// Extra wide for all-caps
        public static let extraWide: CGFloat = 1.5
    }

    /// Line heights as multipliers
    public enum LineHeight {
        public static let tight: CGFloat = 1.1
        public static let normal: CGFloat = 1.3
        public static let relaxed: CGFloat = 1.5
    }
}

// MARK: - Font Styles
//
// These resolve through the theme's font scheme, so views pick up the active
// theme's typeface via the `\.theme` environment — `.font(theme.jsTitle)`
// re-resolves whenever the theme (and therefore the environment) changes.
// To swap fonts, edit the theme's `fonts` scheme (see `StandardTheme.fonts`),
// not these accessors.
//
// Sizes/weights still come from `TypographyTokens.Size` / `.Weight`, so a
// theme only chooses the typeface per role; the scale stays consistent.

/// Pre-configured font styles, resolved against the theme's font scheme
public extension Theme {
    /// Display font for hero titles (52pt bold)
    var jsDisplay: Font {
        fonts.font(
            named: fonts.display,
            size: TypographyTokens.Size.display,
            weight: TypographyTokens.Weight.display
        )
    }

    /// Headline font for section headers (32pt semibold)
    var jsHeadline: Font {
        fonts.font(
            named: fonts.headline,
            size: TypographyTokens.Size.headline,
            weight: TypographyTokens.Weight.headline
        )
    }

    /// Title font for card titles (24pt semibold)
    var jsTitle: Font {
        fonts.font(
            named: fonts.title,
            size: TypographyTokens.Size.title,
            weight: TypographyTokens.Weight.title
        )
    }

    /// Overview font for long text descriptions (24pt medium)
    var jsOverview: Font {
        fonts.font(
            named: fonts.overview,
            size: TypographyTokens.Size.overview,
            weight: TypographyTokens.Weight.overview
        )
    }

    /// Body font for descriptions (22pt regular)
    var jsBody: Font {
        fonts.font(
            named: fonts.body,
            size: TypographyTokens.Size.body,
            weight: TypographyTokens.Weight.body
        )
    }

    /// Caption font for metadata (18pt regular)
    var jsCaption: Font {
        fonts.font(
            named: fonts.caption,
            size: TypographyTokens.Size.caption,
            weight: TypographyTokens.Weight.caption
        )
    }

    /// Small font for badges (12pt regular)
    var jsSmall: Font {
        fonts.font(
            named: fonts.small,
            size: TypographyTokens.Size.small,
            weight: .regular
        )
    }
}

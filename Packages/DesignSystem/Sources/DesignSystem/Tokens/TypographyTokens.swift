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
        public static let caption: CGFloat = 14

        /// Small - 12pt (badges, labels)
        public static let small: CGFloat = 12
    }

    /// Font weights
    public enum Weight {
        public static let display: Font.Weight = .bold
        public static let headline: Font.Weight = .semibold
        public static let title: Font.Weight = .medium
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
// These resolve through the ACTIVE THEME's font scheme (`AppFontConfig.scheme`),
// so call sites never change — `.font(.jsTitle)` automatically picks up whatever
// typeface the current theme assigns to that role. To swap fonts, edit the
// theme's `fonts` scheme (see `StandardTheme.fonts`), not these accessors.
//
// Sizes/weights still come from `TypographyTokens.Size` / `.Weight` below, so a
// theme only chooses the typeface per role; the scale stays consistent.

/// Pre-configured font styles for the app
public extension Font {
    /// Display font for hero titles (52pt bold)
    static var jsDisplay: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.display,
            size: TypographyTokens.Size.display,
            weight: TypographyTokens.Weight.display
        )
    }

    /// Headline font for section headers (32pt semibold)
    static var jsHeadline: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.headline,
            size: TypographyTokens.Size.headline,
            weight: TypographyTokens.Weight.headline
        )
    }

    /// Title font for card titles (24pt medium)
    static var jsTitle: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.title,
            size: TypographyTokens.Size.title,
            weight: TypographyTokens.Weight.title
        )
    }

    /// Overview font for long text descriptions (24pt medium)
    static var jsOverview: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.overview,
            size: TypographyTokens.Size.overview,
            weight: TypographyTokens.Weight.overview
        )
    }

    /// Body font for descriptions (22pt regular)
    static var jsBody: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.body,
            size: TypographyTokens.Size.body,
            weight: TypographyTokens.Weight.body
        )
    }

    /// Caption font for metadata (14pt regular)
    static var jsCaption: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.caption,
            size: TypographyTokens.Size.caption,
            weight: TypographyTokens.Weight.caption
        )
    }

    /// Small font for badges (12pt regular)
    static var jsSmall: Font {
        AppFontConfig.scheme.font(
            named: AppFontConfig.scheme.small,
            size: TypographyTokens.Size.small,
            weight: .regular
        )
    }
}

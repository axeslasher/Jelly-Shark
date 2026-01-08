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

        /// Body - 18pt (descriptions)
        public static let body: CGFloat = 18

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

/// Pre-configured font styles for the app
public extension Font {
    /// Display font for hero titles (52pt bold)
    static var jsDisplay: Font {
        .system(size: TypographyTokens.Size.display, weight: TypographyTokens.Weight.display)
    }

    /// Headline font for section headers (32pt semibold)
    static var jsHeadline: Font {
        .system(size: TypographyTokens.Size.headline, weight: TypographyTokens.Weight.headline)
    }

    /// Title font for card titles (24pt medium)
    static var jsTitle: Font {
        .system(size: TypographyTokens.Size.title, weight: TypographyTokens.Weight.title)
    }

    /// Body font for descriptions (18pt regular)
    static var jsBody: Font {
        .system(size: TypographyTokens.Size.body, weight: TypographyTokens.Weight.body)
    }

    /// Caption font for metadata (14pt regular)
    static var jsCaption: Font {
        .system(size: TypographyTokens.Size.caption, weight: TypographyTokens.Weight.caption)
    }

    /// Small font for badges (12pt regular)
    static var jsSmall: Font {
        .system(size: TypographyTokens.Size.small, weight: .regular)
    }
}

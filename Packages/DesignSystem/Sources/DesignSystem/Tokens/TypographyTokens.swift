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


        /// Caption - 18pt (metadata)
        public static let caption: CGFloat = 18

        /// Small - 12pt (badges, labels)
        public static let small: CGFloat = 12

        /// Eyebrow - 18pt (uppercase mini-labels above values)
        public static let eyebrow: CGFloat = 18

        /// Certificate - 18pt (the age-rating badge)
        public static let certificate: CGFloat = 18
    }

    /// Font weights
    public enum Weight {
        public static let display: Font.Weight = .bold
        public static let headline: Font.Weight = .semibold
        public static let title: Font.Weight = .semibold
        public static let overview: Font.Weight = .medium
        public static let body: Font.Weight = .regular
        public static let caption: Font.Weight = .regular
        public static let small: Font.Weight = .regular
        public static let eyebrow: Font.Weight = .bold
        public static let certificate: Font.Weight = .bold

        // Emphasis tiers components layer on any role (see `TypeEmphasis`).
        // These are the Standard-scale defaults; themes remap them per role.
        public static let subtle: Font.Weight = .medium
        public static let emphasized: Font.Weight = .semibold
        public static let strong: Font.Weight = .bold
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
// To swap fonts (or tune a role's size/weight/tracking), edit the theme's
// `fonts` scheme (see `StandardTheme.fonts`), not these accessors.
//
// `TypographyTokens.Size` / `.Weight` hold the Standard-scale defaults that
// seed every scheme; a theme overrides per role from there.

/// Pre-configured font styles, resolved against the theme's font scheme
public extension Theme {
    /// Font for a role at a given emphasis tier. Components that used to pin
    /// `.fontWeight(...)` on a themed font ask for a tier instead, so each
    /// theme decides what "emphasized" means for that role's typeface:
    /// `.font(theme.js(.body, .emphasized))`.
    func js(_ role: TypeRole, _ emphasis: TypeEmphasis = .regular) -> Font {
        fonts[role].font(emphasis)
    }

    /// Per-role letter tracking. `Font` can't carry tracking, so views apply
    /// it themselves: `.tracking(theme.jsTracking(.eyebrow))`.
    func jsTracking(_ role: TypeRole) -> CGFloat {
        fonts[role].tracking
    }

    /// Display font for hero titles (Standard: 52pt bold)
    var jsDisplay: Font { js(.display) }

    /// Headline font for section headers (Standard: 32pt semibold)
    var jsHeadline: Font { js(.headline) }

    /// Title font for card titles (Standard: 24pt semibold)
    var jsTitle: Font { js(.title) }

    /// Overview font for long text descriptions (Standard: 24pt medium)
    var jsOverview: Font { js(.overview) }

    /// Body font for descriptions (Standard: 22pt regular)
    var jsBody: Font { js(.body) }

    /// Caption font for metadata (Standard: 18pt regular)
    var jsCaption: Font { js(.caption) }

    /// Small font for badges (Standard: 12pt regular)
    var jsSmall: Font { js(.small) }

    /// Eyebrow font for uppercase mini-labels (Standard: 18pt bold, wide
    /// tracking — apply the tracking at the view via `jsTracking(.eyebrow)`)
    var jsEyebrow: Font { js(.eyebrow) }

    /// Certificate font for the age-rating badge (Standard: Zodiak 18pt bold)
    var jsCertificate: Font { js(.certificate) }
}

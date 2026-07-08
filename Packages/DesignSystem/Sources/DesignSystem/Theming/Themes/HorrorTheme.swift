import SwiftUI

/// The Horror theme - atmospheric dread, blood reds on desaturated darkness
/// Colors are first-pass BaseColors picks pending hand curation; each choice
/// must keep the WCAG floors enforced by ThemeCatalogTests.
public struct HorrorTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "horror"
    public let name = "Horror"
    public let description = "Atmospheric dread, visceral intensity. Slow, tension-building motion over blood-red accents."

    // MARK: - Colors

    public let background = BaseColors.neutral950
    public let surface = BaseColors.neutral900
    public let surfaceElevated = BaseColors.neutral800
    public let primary = BaseColors.stone200
    public let secondary = BaseColors.neutral300
    public let tertiary = BaseColors.neutral400
    public let onPlatter = BaseColors.neutral900
    public let onPlatterSecondary = BaseColors.neutral600
    public let accent = BaseColors.red600
    public let accentSecondary = BaseColors.red800
    public let success = BaseColors.green600
    public let warning = BaseColors.amber600
    public let error = BaseColors.red500
    public let focusRing = BaseColors.red500.opacity(0.8)
    public let focusFill: Color? = BaseColors.red200
    public let onFocusFill = BaseColors.red950
    public let onFocusFillSecondary = BaseColors.red900

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.zodiak,
        headline: FontFamily.zodiak,
        title: FontFamily.satoshi,
        overview: FontFamily.satoshi,
        body: FontFamily.satoshi,
        caption: FontFamily.satoshi,
        small: FontFamily.satoshi
    )

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.4
    public let animation: Animation = MotionTokens.horrorAnimation

    // MARK: - Initialization

    public init() {}
}

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

    public let background = BaseColors.stone950
    public let surface = BaseColors.stone900
    public let surfaceElevated = BaseColors.stone800
    public let primary = BaseColors.amber50
    public let secondary = BaseColors.amber50.opacity(0.8)
    public let tertiary = BaseColors.amber50.opacity(0.5)
    public let onPlatter = BaseColors.slate900
    public let onPlatterSecondary = BaseColors.slate600
    public let accent = BaseColors.red500
    public let accentSecondary = BaseColors.red800
    public let success = BaseColors.green600
    public let warning = BaseColors.amber600
    public let error = BaseColors.red500
    public let focusRing = BaseColors.red500.opacity(0.8)
    public let focusFill: Color? = BaseColors.red600.opacity(0.3)
    public let onFocusFill = BaseColors.amber50
    public let onFocusFillSecondary = BaseColors.amber50.opacity(0.8)

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.grenzeGotisch,
        headline: FontFamily.grenzeGotisch,
        title: FontFamily.grenze,
        overview: FontFamily.sentient,
        body: FontFamily.sentient,
        caption: FontFamily.sentient,
        small: FontFamily.sentient,
        certificate: TypeStyle(
            family: FontFamily.zodiak,
            size: TypographyTokens.Size.certificate,
            weight: TypographyTokens.Weight.certificate
        )
    )

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.4
    public let animation: Animation = MotionTokens.horrorAnimation

    // MARK: - Initialization

    public init() {}
}

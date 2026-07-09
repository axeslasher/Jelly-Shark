import SwiftUI

/// The Action theme - kinetic energy, electric cyan over steel blues
/// Colors are first-pass BaseColors picks pending hand curation; each choice
/// must keep the WCAG floors enforced by ThemeCatalogTests.
public struct ActionTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "action"
    public let name = "Action"
    public let description = "Kinetic energy, technological precision. Fast, explosive motion with electric cyan highlights."

    // MARK: - Colors

    public let background = BaseColors.gray950
    public let surface = BaseColors.gray900
    public let surfaceElevated = BaseColors.slate500
    public let primary = BaseColors.slate50
    public let secondary = BaseColors.gray300
    public let tertiary = BaseColors.slate400
    public let onPlatter = BaseColors.slate900
    public let onPlatterSecondary = BaseColors.slate600
    public let accent = BaseColors.rose500
    public let accentSecondary = BaseColors.rose600
    public let success = BaseColors.emerald400
    public let warning = BaseColors.yellow400
    public let error = BaseColors.red500
    public let focusRing = BaseColors.rose600.opacity(0.8)
    public let focusFill: Color? = BaseColors.slate700.opacity(0.5)
    public let onFocusFill = BaseColors.slate100
    public let onFocusFillSecondary = BaseColors.gray300

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.supreme,
        headline: FontFamily.supreme,
        title: FontFamily.supreme,
        overview: FontFamily.generalSans,
        body: FontFamily.generalSans,
        caption: FontFamily.generalSans,
        small: FontFamily.generalSans,
        certificate: TypeStyle(
            family: FontFamily.zodiak,
            size: TypographyTokens.Size.certificate,
            weight: TypographyTokens.Weight.certificate
        )
    )

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.2
    public let animation: Animation = MotionTokens.actionAnimation

    // MARK: - Initialization

    public init() {}
}

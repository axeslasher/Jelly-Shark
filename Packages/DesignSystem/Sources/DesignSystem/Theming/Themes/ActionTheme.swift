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

    public let background = BaseColors.slate950
    public let surface = BaseColors.slate900
    public let surfaceElevated = BaseColors.slate800
    public let primary = BaseColors.sky100
    public let secondary = BaseColors.slate300
    public let tertiary = BaseColors.slate400
    public let onPlatter = BaseColors.slate900
    public let onPlatterSecondary = BaseColors.slate600
    public let accent = BaseColors.cyan400
    public let accentSecondary = BaseColors.cyan600
    public let success = BaseColors.emerald400
    public let warning = BaseColors.yellow400
    public let error = BaseColors.rose500
    public let focusRing = BaseColors.cyan400.opacity(0.8)
    public let focusFill: Color? = BaseColors.cyan200
    public let onFocusFill = BaseColors.slate950
    public let onFocusFillSecondary = BaseColors.slate700

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.spaceGrotesk,
        headline: FontFamily.spaceGrotesk,
        title: FontFamily.spaceGrotesk,
        overview: FontFamily.satoshi,
        body: FontFamily.satoshi,
        caption: FontFamily.satoshi,
        small: FontFamily.satoshi
    )

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.2
    public let animation: Animation = MotionTokens.actionAnimation

    // MARK: - Initialization

    public init() {}
}

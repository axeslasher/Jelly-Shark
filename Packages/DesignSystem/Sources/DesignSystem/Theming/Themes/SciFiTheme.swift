import SwiftUI

/// The Sci-Fi theme - deep-space greens under engineered typography
/// Colors are first-pass BaseColors picks pending hand curation; each choice
/// must keep the WCAG floors enforced by ThemeCatalogTests.
public struct SciFiTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "sciFi"
    public let name = "Sci-Fi"
    public let description = "Deep-space greens, engineered precision. Slow, weightless motion with a phosphor glow."

    // MARK: - Colors

    public let background = BaseColors.emerald950
    public let surface = BaseColors.emerald900
    public let surfaceElevated = BaseColors.emerald800
    public let primary = BaseColors.emerald50
    public let secondary = BaseColors.emerald300
    public let tertiary = BaseColors.emerald400
    public let onPlatter = BaseColors.emerald900
    public let onPlatterSecondary = BaseColors.emerald600
    public let accent = BaseColors.emerald400
    public let accentSecondary = BaseColors.teal500
    public let success = BaseColors.green500
    public let warning = BaseColors.amber500
    public let error = BaseColors.red500
    public let focusRing = BaseColors.emerald400.opacity(0.8)
    public let focusFill: Color? = BaseColors.emerald200
    public let onFocusFill = BaseColors.emerald950
    public let onFocusFillSecondary = BaseColors.emerald900

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.spaceGrotesk,
        headline: FontFamily.spaceGrotesk,
        title: FontFamily.spaceGrotesk,
        overview: FontFamily.spaceGrotesk,
        body: FontFamily.spaceGrotesk,
        caption: FontFamily.spaceGrotesk,
        small: FontFamily.spaceGrotesk
    )

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.45
    public let animation: Animation = MotionTokens.sciFiAnimation

    // MARK: - Initialization

    public init() {}
}

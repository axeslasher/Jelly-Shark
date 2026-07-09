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

    public let background = BaseColors.teal950
    public let surface = BaseColors.teal900
    public let surfaceElevated = BaseColors.teal800
    public let primary = BaseColors.lime200
    public let secondary = BaseColors.lime100
    public let tertiary = BaseColors.lime300
    public let onPlatter = BaseColors.teal900
    public let onPlatterSecondary = BaseColors.teal600
    public let accent = BaseColors.lime400
    public let accentSecondary = BaseColors.lime600
    public let success = BaseColors.green500
    public let warning = BaseColors.amber500
    public let error = BaseColors.red500
    public let focusRing = BaseColors.lime400.opacity(0.8)
    public let focusFill: Color? = BaseColors.lime200
    public let onFocusFill = BaseColors.lime950
    public let onFocusFillSecondary = BaseColors.lime900

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.technor,
        headline: FontFamily.technor,
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

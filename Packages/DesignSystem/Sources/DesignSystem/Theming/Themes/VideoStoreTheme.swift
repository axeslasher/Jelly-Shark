import SwiftUI

/// The Video Store theme - 90s rental-store nostalgia in deep blue and gold
/// Colors are first-pass BaseColors picks pending hand curation; each choice
/// must keep the WCAG floors enforced by ThemeCatalogTests.
public struct VideoStoreTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "videoStore"
    public let name = "Video Store"
    public let description = "90s nostalgia, Friday night vibes. Bouncy, playful motion in deep blue and gold."

    // MARK: - Colors

    public let background = BaseColors.blue950
    public let surface = BaseColors.blue900
    public let surfaceElevated = BaseColors.blue800
    public let primary = BaseColors.amber50
    public let secondary = BaseColors.stone200
    public let tertiary = BaseColors.stone300
    public let onPlatter = BaseColors.blue950
    public let onPlatterSecondary = BaseColors.blue700
    public let accent = BaseColors.yellow400
    public let accentSecondary = BaseColors.blue400
    public let success = BaseColors.lime500
    public let warning = BaseColors.orange400
    public let error = BaseColors.red400
    public let focusRing = BaseColors.yellow400.opacity(0.8)
    public let focusFill: Color? = BaseColors.yellow200
    public let onFocusFill = BaseColors.blue950
    public let onFocusFillSecondary = BaseColors.blue800

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.satoshi,
        headline: FontFamily.satoshi,
        title: FontFamily.satoshi,
        overview: FontFamily.satoshi,
        body: FontFamily.satoshi,
        caption: FontFamily.satoshi,
        small: FontFamily.satoshi
    )

    public let fontWeightDisplay: Font.Weight = .black

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.35
    public let animation: Animation = MotionTokens.videoStoreAnimation

    // MARK: - Initialization

    public init() {}
}

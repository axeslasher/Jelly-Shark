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
    public let primary = BaseColors.yellow100
    public let secondary = BaseColors.yellow100.opacity(0.9)
    public let tertiary = BaseColors.yellow300.opacity(0.7)
    public let onPlatter = BaseColors.blue950
    public let onPlatterSecondary = BaseColors.blue700
    public let accent = BaseColors.yellow400
    public let accentSecondary = BaseColors.blue400
    public let success = BaseColors.lime500
    public let warning = BaseColors.orange400
    public let error = BaseColors.red400
    public let focusRing = BaseColors.yellow400.opacity(0.8)
    public let focusFill: Color? = BaseColors.blue400.opacity(0.6)
    public let onFocusFill = BaseColors.yellow300
    public let onFocusFillSecondary = BaseColors.yellow400

    // MARK: - Typography

    public let fonts = FontScheme(
        display: FontFamily.nippo,
        headline: FontFamily.nippo,
        title: FontFamily.generalSans,
        overview: FontFamily.supreme,
        body: FontFamily.supreme,
        caption: FontFamily.supreme,
        small: FontFamily.supreme
    )

    public let fontWeightDisplay: Font.Weight = .black

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.35
    public let animation: Animation = MotionTokens.videoStoreAnimation

    // MARK: - Initialization

    public init() {}
}

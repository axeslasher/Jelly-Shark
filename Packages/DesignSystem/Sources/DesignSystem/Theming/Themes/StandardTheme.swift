import SwiftUI

/// The Standard theme - elegant, timeless, Apple-quality baseline
/// This is the default theme that lets content shine
public struct StandardTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "standard"
    public let name = "Standard"
    public let description = "Elegant, timeless baseline. Professional and unobtrusive, letting content shine."

    // MARK: - Colors

    public let background = BaseColors.zinc950
    public let surface = BaseColors.zinc900
    public let surfaceElevated = BaseColors.zinc800
    public let primary = BaseColors.zinc50
    public let secondary = BaseColors.zinc300
    public let tertiary = BaseColors.zinc400
    public let onPlatter = BaseColors.zinc900
    public let onPlatterSecondary = BaseColors.zinc600
    public let accent = BaseColors.orange500
    public let accentSecondary = BaseColors.orange600
    public let success = BaseColors.green500
    public let warning = BaseColors.yellow500
    public let error = BaseColors.red500
    public let focusRing = BaseColors.white.opacity(0.8)

    // MARK: - Typography

    ///
    /// ┌────────────────────────────────────────────────────────────────────────┐
    /// │ SWAP FONTS HERE. Each role points at a `FontFamily` name (or `nil` for  │
    /// │ the system font / San Francisco). Mix and match freely, then rebuild.   │
    /// │                                                                          │
    /// │ Sizes, weights, emphasis weights, and tracking default to the Standard  │
    /// │ scale (TypographyTokens). To tune a role beyond its family, mutate the  │
    /// │ scheme in a closure initializer:                                         │
    /// │                                                                          │
    /// │   public let fonts: FontScheme = {                                       │
    /// │       var scheme = FontScheme(display: FontFamily.generalSans, ...)      │
    /// │       scheme.display.weight = .black   // heavier hero                   │
    /// │       scheme.display.size = 56         // x-height compensation          │
    /// │       scheme.body.emphasizedWeight = .bold  // what "emphasized" means   │
    /// │       return scheme                                                      │
    /// │   }()                                                                    │
    /// └────────────────────────────────────────────────────────────────────────┘
    public let fonts = FontScheme(
        display: FontFamily.generalSans,
        headline: FontFamily.generalSans,
        title: FontFamily.generalSans,
        overview: FontFamily.satoshi,
        body: FontFamily.satoshi,
        caption: FontFamily.satoshi,
        small: FontFamily.satoshi,
        certificate: TypeStyle(
            family: FontFamily.zodiak,
            size: TypographyTokens.Size.certificate,
            weight: TypographyTokens.Weight.certificate,
        ),
    )

    // MARK: - Motion

    public let transitionDuration: TimeInterval = MotionTokens.durationNormal
    public let animation: Animation = MotionTokens.standardAnimation
    public let focusScale: CGFloat = 1.05

    // MARK: - Geometry

    public let cornerRadius: CGFloat = 8
    public let cornerRadiusLarge: CGFloat = 16
    public let borderWidth: CGFloat = 1

    // MARK: - Initialization

    public init() {}
}

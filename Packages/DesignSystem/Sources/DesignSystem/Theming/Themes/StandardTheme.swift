import SwiftUI

/// The Standard theme - elegant, timeless, Apple-quality baseline
/// This is the default theme that lets content shine
public struct StandardTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "standard"
    public let name = "Standard"
    public let description = "Elegant, timeless baseline. Professional and unobtrusive, letting content shine."

    // MARK: - Colors

    public let background = ColorTokens.Standard.background
    public let surface = ColorTokens.Standard.surface
    public let surfaceElevated = ColorTokens.Standard.surfaceElevated
    public let primary = ColorTokens.Standard.primary
    public let secondary = ColorTokens.Standard.secondary
    public let tertiary = ColorTokens.Standard.tertiary
    public let accent = ColorTokens.Standard.accent
    public let accentSecondary = ColorTokens.Standard.accentSecondary
    public let success = ColorTokens.Standard.success
    public let warning = ColorTokens.Standard.warning
    public let error = ColorTokens.Standard.error
    public let focusRing = ColorTokens.Standard.focusRing

    // MARK: - Typography
    //
    // ┌────────────────────────────────────────────────────────────────────────┐
    // │ SWAP FONTS HERE. Each role points at a `FontFamily` name (or `nil` for  │
    // │ the system font / San Francisco). Mix and match freely, then rebuild.   │
    // │                                                                          │
    // │ Current mapping — "Zodiak display, sans elsewhere":                      │
    // │   • Zodiak (serif) for the hero Display                                  │
    // │   • Satoshi for section Headlines + Titles                               │
    // │   • General Sans for Overview / Body / Caption / Small                   │
    // │                                                                          │
    // │ A few alternatives to try:                                               │
    // │   Serif reading:  overview: FontFamily.zodiak                            │
    // │   Satoshi hero:   display/headline: .satoshi, title/body: .generalSans   │
    // │   All system:     set any role to `nil` (or use `.system`)               │
    // └────────────────────────────────────────────────────────────────────────┘
    public let fonts = FontScheme(
        display: FontFamily.generalSans,
        headline: FontFamily.generalSans,
        title: FontFamily.generalSans,
        overview: FontFamily.satoshi,
        body: FontFamily.satoshi,
        caption: FontFamily.satoshi,
        small: FontFamily.satoshi
    )

    public let fontFamily: String? = nil // Legacy single-family hook (unused by tokens)
    public let fontWeightDisplay: Font.Weight = .bold
    public let fontWeightBody: Font.Weight = .regular
    public let letterSpacing: CGFloat = 0

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

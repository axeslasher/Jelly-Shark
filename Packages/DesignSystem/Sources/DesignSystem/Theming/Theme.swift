import SwiftUI

/// Protocol defining a complete theme for Jelly Shark
/// Themes are genre-inspired visual languages that define color, typography, motion, and spacing
public protocol Theme: Sendable {
    // MARK: - Identity

    /// Unique identifier for the theme
    var id: String { get }

    /// Display name of the theme
    var name: String { get }

    /// Description of the theme's mood and use case
    var description: String { get }

    // MARK: - Colors

    /// Primary background color
    var background: Color { get }

    /// Surface color for cards and elevated elements
    var surface: Color { get }

    /// Higher elevation surface color
    var surfaceElevated: Color { get }

    /// Primary content color (text, icons)
    var primary: Color { get }

    /// Secondary content color
    var secondary: Color { get }

    /// Tertiary content color
    var tertiary: Color { get }

    /// Accent color for interactive elements
    var accent: Color { get }

    /// Secondary accent color
    var accentSecondary: Color { get }

    /// Success state color
    var success: Color { get }

    /// Warning state color
    var warning: Color { get }

    /// Error state color
    var error: Color { get }

    /// Focus ring color
    var focusRing: Color { get }

    // MARK: - Typography

    /// Primary font family name (nil for system font)
    var fontFamily: String? { get }

    /// Display font weight
    var fontWeightDisplay: Font.Weight { get }

    /// Body font weight
    var fontWeightBody: Font.Weight { get }

    /// Default letter spacing
    var letterSpacing: CGFloat { get }

    // MARK: - Spacing

    /// Base spacing unit
    var spacingUnit: CGFloat { get }

    /// Card internal padding
    var cardPadding: CGFloat { get }

    /// Space between sections
    var sectionSpacing: CGFloat { get }

    // MARK: - Motion

    /// Default transition duration
    var transitionDuration: TimeInterval { get }

    /// Default animation curve
    var animation: Animation { get }

    /// Focus scale factor
    var focusScale: CGFloat { get }

    // MARK: - Geometry

    /// Default corner radius
    var cornerRadius: CGFloat { get }

    /// Large corner radius (for cards)
    var cornerRadiusLarge: CGFloat { get }

    /// Default border width
    var borderWidth: CGFloat { get }
}

// MARK: - Theme Identifier

/// Available theme identifiers
public enum ThemeIdentifier: String, CaseIterable, Sendable, Codable {
    case standard
    case horror
    case action
    case videoStore

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .horror: return "Horror"
        case .action: return "Action"
        case .videoStore: return "Video Store"
        }
    }
}

// MARK: - Default Values

public extension Theme {
    // Default typography (can be overridden)
    var fontFamily: String? { nil }
    var fontWeightDisplay: Font.Weight { .bold }
    var fontWeightBody: Font.Weight { .regular }
    var letterSpacing: CGFloat { 0 }

    // Default spacing
    var spacingUnit: CGFloat { SpacingTokens.unit }
    var cardPadding: CGFloat { SpacingTokens.cardPadding }
    var sectionSpacing: CGFloat { SpacingTokens.sectionSpacing }

    // Default motion
    var transitionDuration: TimeInterval { MotionTokens.durationNormal }
    var animation: Animation { MotionTokens.standard }
    var focusScale: CGFloat { MotionTokens.focusScale }

    // Default geometry
    var cornerRadius: CGFloat { 8 }
    var cornerRadiusLarge: CGFloat { 16 }
    var borderWidth: CGFloat { 1 }
}

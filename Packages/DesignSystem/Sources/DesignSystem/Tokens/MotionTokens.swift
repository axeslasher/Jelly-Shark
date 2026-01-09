import SwiftUI

/// Motion and animation tokens for the design system
public enum MotionTokens {
    // MARK: - Durations

    /// Quick interactions (150ms)
    public static let durationFast: Double = 0.15

    /// Standard animations (300ms)
    public static let durationNormal: Double = 0.3

    /// Slower, more dramatic animations (500ms)
    public static let durationSlow: Double = 0.5

    /// Theme transition duration (500ms)
    public static let durationThemeTransition: Double = 0.5

    // MARK: - Standard Animations

    /// Default animation for most interactions
    public static var standard: Animation {
        .easeInOut(duration: durationNormal)
    }

    /// Quick animation for micro-interactions
    public static var fast: Animation {
        .easeOut(duration: durationFast)
    }

    /// Slower animation for emphasis
    public static var slow: Animation {
        .easeInOut(duration: durationSlow)
    }

    /// Spring animation for playful feedback
    public static var spring: Animation {
        .spring(response: 0.35, dampingFraction: 0.7)
    }

    /// Snappy spring for quick feedback
    public static var snappySpring: Animation {
        .spring(response: 0.25, dampingFraction: 0.8)
    }

    // MARK: - Theme-Specific Animations

    /// Standard theme - smooth and refined
    public static var standardAnimation: Animation {
        .easeInOut(duration: durationNormal)
    }

    /// Horror theme - slower, tension-building
    public static var horrorAnimation: Animation {
        .easeIn(duration: 0.4)
    }

    /// Action theme - fast and explosive
    public static var actionAnimation: Animation {
        .easeOut(duration: 0.2)
    }

    /// Video Store theme - bouncy and playful
    public static var videoStoreAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.6)
    }

    // MARK: - Focus Animations

    /// Scale factor when focused (tvOS)
    public static let focusScale: CGFloat = 1.05

    /// Scale factor for pressed state
    public static let pressedScale: CGFloat = 0.98

    /// Focus animation
    public static var focusAnimation: Animation {
        .spring(response: 0.3, dampingFraction: 0.7)
    }
}

// MARK: - Animation Modifier

/// View modifier to apply theme-appropriate animation
public struct ThemeAnimationModifier: ViewModifier {
    let animation: Animation

    public func body(content: Content) -> some View {
        content.animation(animation, value: UUID())
    }
}

public extension View {
    /// Apply the standard theme animation
    func themeAnimation(_ animation: Animation = MotionTokens.standard) -> some View {
        self.animation(animation, value: UUID())
    }
}

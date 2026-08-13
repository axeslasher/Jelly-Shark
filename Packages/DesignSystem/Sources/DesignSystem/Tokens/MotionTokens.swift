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

    /// Sci-Fi theme - slow, weightless drift
    public static var sciFiAnimation: Animation {
        .easeInOut(duration: 0.45)
    }

    // MARK: - Focus Animations

    /// Scale factor when focused (tvOS)
    public static let focusScale: CGFloat = 1.05

    /// Scale factor for pressed state
    public static let pressedScale: CGFloat = 0.98

    /// Opacity of a shelf card's captions while the card is unfocused; focused
    /// captions render at full strength.
    ///
    /// The accessibility wall is just under 0.5 — every theme's caption roles
    /// still clear WCAG AA (4.5:1) at 0.5 and fail by 0.45, with Horror's
    /// already-translucent `secondary` the first to go. `ThemeCatalogTests`
    /// guards this, so raising the dim is a one-line change here.
    public static let captionIdleOpacity: Double = 0.6

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

private struct MotionTokenRow: View {
    @Environment(\.theme) private var theme

    let name: String
    let animation: Animation

    @State private var trailing = false

    var body: some View {
        HStack(spacing: SpacingTokens.md) {
            Text(name)
                .jsStyle(.caption)
                .foregroundStyle(theme.secondary)
                .frame(width: 300, alignment: .leading)

            Circle()
                .fill(theme.accent)
                .frame(width: 20, height: 20)
                .offset(x: trailing ? 200 : 0)
                .animation(animation.repeatForever(autoreverses: true), value: trailing)
        }
        .onAppear { trailing = true }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: SpacingTokens.md) {
        MotionTokenRow(name: "fast (0.15s)", animation: MotionTokens.fast)
        MotionTokenRow(name: "standard (0.3s)", animation: MotionTokens.standard)
        MotionTokenRow(name: "slow (0.5s)", animation: MotionTokens.slow)
        MotionTokenRow(name: "spring", animation: MotionTokens.spring)
        MotionTokenRow(name: "snappySpring", animation: MotionTokens.snappySpring)
        MotionTokenRow(name: "horrorAnimation", animation: MotionTokens.horrorAnimation)
        MotionTokenRow(name: "actionAnimation", animation: MotionTokens.actionAnimation)
        MotionTokenRow(name: "videoStoreAnimation", animation: MotionTokens.videoStoreAnimation)
        MotionTokenRow(name: "sciFiAnimation", animation: MotionTokens.sciFiAnimation)
    }
    .padding(SpacingTokens.screenPadding)
    .withThemeEnvironment(.preview())
}

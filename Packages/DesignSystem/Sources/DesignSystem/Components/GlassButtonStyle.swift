import SwiftUI

public extension View {
    /// The Liquid Glass button treatment used by prominent actions. `.glass` is
    /// unavailable on macOS 15, which the package builds for only to run tests;
    /// there it falls back to `.bordered`.
    ///
    /// - Parameters:
    ///   - tint: The theme's `focusFill`. The system `.glass` style always
    ///     lifts to a white platter on focus and ignores `Glass.tint` there,
    ///     so passing a tint switches to ``ThemedGlassButtonStyle``, which
    ///     draws its own tinted platter. `nil` keeps the system style.
    ///   - circular: Draw the themed platter as a circle with uniform padding
    ///     (for square glyph labels). The custom style can't see
    ///     `buttonBorderShape(.circle)`, which only informs system styles.
    @ViewBuilder
    func glassButtonStyle(tint: Color? = nil, circular: Bool = false) -> some View {
        #if os(macOS)
        buttonStyle(.bordered)
        #else
        if let tint {
            buttonStyle(ThemedGlassButtonStyle(tint: tint, circular: circular))
        } else {
            buttonStyle(.glass(.clear))
        }
        #endif
    }
}

#if !os(macOS)
/// Glass button that renders its own focus platter in a theme color.
///
/// tvOS's system button styles (`.glass`, `.glassProminent`, `.bordered…`)
/// all lift to the fixed white system platter on focus — there is no public
/// hook to recolor it. This style reproduces the treatment with
/// `glassEffect`, which does honor a tint: clear glass at rest, a tinted
/// platter plus scale-up when focused.
///
/// The focused label color defaults to the theme's `onFocusFill`; labels that
/// set an explicit `foregroundStyle` (e.g. ``CircleActionButton``'s icon)
/// still win, matching how the system platter treats them.
public struct ThemedGlassButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let tint: Color
    let circular: Bool

    public init(tint: Color, circular: Bool = false) {
        self.tint = tint
        self.circular = circular
    }

    public func makeBody(configuration: Configuration) -> some View {
        paddedLabel(configuration.label)
            .foregroundStyle(isFocused ? theme.onFocusFill : theme.primary)
            .glassEffect(
                isFocused ? .regular.tint(tint).interactive() : .clear,
                in: circular ? AnyShape(.circle) : AnyShape(.capsule)
            )
            .scaleEffect(isFocused ? theme.focusScale : 1)
            .scaleEffect(configuration.isPressed ? MotionTokens.pressedScale : 1)
            .animation(theme.animation, value: isFocused)
            .animation(MotionTokens.fast, value: configuration.isPressed)
    }

    /// Circles need uniform padding so a square glyph label stays square;
    /// capsules breathe wider than they are tall.
    @ViewBuilder
    private func paddedLabel(_ label: Configuration.Label) -> some View {
        if circular {
            label.padding(SpacingTokens.sm)
        } else {
            label
                .padding(.horizontal, SpacingTokens.md)
                .padding(.vertical, SpacingTokens.sm)
        }
    }
}
#endif

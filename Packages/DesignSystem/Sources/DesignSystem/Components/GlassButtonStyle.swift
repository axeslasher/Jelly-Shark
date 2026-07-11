import SwiftUI

public extension View {
    /// The Liquid Glass button treatment used by prominent actions. `.glass`
    /// and the `glassEffect` the themed styles rely on are unavailable on
    /// visionOS, where this falls back to the system `.bordered` style (which
    /// carries its own native Liquid Glass).
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
        #if os(tvOS)
            if let tint {
                buttonStyle(ThemedGlassButtonStyle(tint: tint, circular: circular))
            } else {
                buttonStyle(.glass(.clear))
            }
        #else
            buttonStyle(.bordered)
        #endif
    }
}

public extension View {
    /// A `.plain`-style button whose focus platter follows the theme. Like the
    /// glass styles, the system `.plain` highlight platter is fixed white, so
    /// a theme with a `focusFill` switches to ``ThemedPlainButtonStyle``.
    ///
    /// - Parameters:
    ///   - tint: The theme's `focusFill`; `nil` keeps the system `.plain` style.
    ///   - cornerRadius: Corner radius of the themed platter (typically the
    ///     theme's `cornerRadiusLarge`).
    @ViewBuilder
    func plainFocusButtonStyle(tint: Color?, cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
            if let tint {
                buttonStyle(ThemedPlainButtonStyle(tint: tint, cornerRadius: cornerRadius))
            } else {
                buttonStyle(.plain)
            }
        #else
            buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
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
                    in: circular ? AnyShape(.circle) : AnyShape(.capsule),
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

    /// `.plain` button that renders its own focus platter in a theme color
    /// (the system highlight platter is fixed white, as with the glass styles).
    ///
    /// The platter draws in the background and bleeds outward past the label via
    /// negative padding — mirroring how the system platter overflows content —
    /// so the resting layout is pixel-identical to `.plain` and text stays
    /// aligned with its neighbors. Content colors are left to the label
    /// (e.g. ``OverviewLabel`` swaps its own text to the on-focus tokens).
    public struct ThemedPlainButtonStyle: ButtonStyle {
        @Environment(\.theme) private var theme
        @Environment(\.isFocused) private var isFocused

        let tint: Color
        let cornerRadius: CGFloat

        public init(tint: Color, cornerRadius: CGFloat) {
            self.tint = tint
            self.cornerRadius = cornerRadius
        }

        public func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    Color.clear
                        .glassEffect(
                            .regular.tint(tint).interactive(),
                            in: .rect(cornerRadius: cornerRadius),
                        )
                        .padding(.horizontal, -SpacingTokens.md)
                        .padding(.vertical, -SpacingTokens.sm)
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(configuration.isPressed ? MotionTokens.pressedScale : 1)
                .animation(theme.animation, value: isFocused)
                .animation(MotionTokens.fast, value: configuration.isPressed)
        }
    }
#endif

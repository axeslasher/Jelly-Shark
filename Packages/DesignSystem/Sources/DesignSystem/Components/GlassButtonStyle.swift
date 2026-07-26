// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

    /// The resting glass capsule and **nothing else** — no platter, no lift,
    /// no label recolor, in any state.
    ///
    /// For controls that present focus themselves, where a second platter is
    /// not just redundant but a liability. `glassButtonStyle(tint:)` can't do
    /// this on either path: a tint draws ``ThemedGlassButtonStyle``'s platter,
    /// and a nil tint falls through to the system `.glass` style's white one,
    /// which offers no way to turn it off at all.
    ///
    /// Both stick on a control whose surroundings *rebuild* during a press —
    /// the season pills, whose `.focusable` gate is keyed to the active season
    /// that pressing one changes. The style never sees the interaction end,
    /// and the platter stays behind, one per press.
    @ViewBuilder
    func inertGlassButtonStyle(circular: Bool = false) -> some View {
        #if os(tvOS)
            buttonStyle(ThemedGlassButtonStyle(tint: nil, circular: circular))
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
    ///
    /// A `nil` tint opts out of the focus treatment entirely — see
    /// ``SwiftUI/View/inertGlassButtonStyle(circular:)``.
    public struct ThemedGlassButtonStyle: ButtonStyle {
        @Environment(\.theme) private var theme
        @Environment(\.isFocused) private var isFocused

        let tint: Color?
        let circular: Bool

        public init(tint: Color?, circular: Bool = false) {
            self.tint = tint
            self.circular = circular
        }

        public func makeBody(configuration: Configuration) -> some View {
            // Resolved once: a nil tint means this button never presents focus
            // at all, so nothing below may key off `isFocused` on its own.
            let platter = isFocused ? tint : nil

            paddedLabel(configuration.label)
                .foregroundStyle(platter == nil ? theme.primary : theme.onFocusFill)
                .glassEffect(
                    platter.map { .regular.tint($0).interactive() } ?? .clear,
                    in: circular ? AnyShape(.circle) : AnyShape(.capsule),
                )
                .scaleEffect(platter == nil ? 1 : theme.focusScale)
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

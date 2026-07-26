import SwiftUI

/// An icon-only, circular action button that reveals its text label beneath the
/// circle while focused (tvOS) or looked at (visionOS) — keeping the action
/// lockup compact when idle.
public struct CircleActionButton: View {
    private let systemImage: String
    private let title: String
    private let tint: Color
    private let focusedTint: Color?
    private let isEnabled: Bool
    private let action: () -> Void

    /// Side of the square the glyph is pinned into — comfortably fits the
    /// widest SF Symbols at the headline size (32pt) so every button renders
    /// the same circle.
    private static let glyphBox: CGFloat = 44

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    /// - Parameter focusedTint: Icon color while the button is focused and
    ///   sitting on the light system platter. Defaults to the theme's
    ///   `onPlatter` — pass a color only to keep a state tint (e.g. the accent)
    ///   visible through focus.
    public init(
        systemImage: String,
        title: String,
        tint: Color,
        focusedTint: Color? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
    ) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.focusedTint = focusedTint
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .jsStyle(.headline)
                // Focus lifts the glass circle to a light platter; the
                // theme's light tints wash out there, so swap to the
                // on-platter color (or the caller's override).
                .foregroundStyle(isFocused ? (focusedTint ?? theme.onFocusFill) : tint)
                // The circle takes its diameter from the label, and SF Symbol
                // glyphs all have different bounding boxes — pin the glyph in
                // a fixed square so swapping symbols ("eye.fill" ⇄
                // "checkmark") can't resize the button.
                .frame(width: Self.glyphBox, height: Self.glyphBox)
        }
        .glassButtonStyle(tint: theme.focusFill, circular: true)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .focused($isFocused)
        .disabled(!isEnabled)
        .hangingActionLabel(title, isFocused: isFocused)
    }
}

// MARK: - Hanging label

public extension View {
    /// Hangs `title` beneath a circular control, revealed while the control is
    /// focused (tvOS) or looked at (visionOS).
    ///
    /// Shared rather than inlined because the reveal works differently per
    /// platform in a way that isn't visible from a call site — and because the
    /// two controls that want it live in different modules, each with its own
    /// verbatim copy. That duplication is why the visionOS reveal, once added,
    /// reached only one of them.
    ///
    /// - Parameter isFocused: tvOS's trigger. visionOS never tells an app where
    ///   someone is looking, so there the reveal comes from a hover effect the
    ///   system runs on the app's behalf, and this is unused.
    func hangingActionLabel(_ title: String, isFocused: Bool) -> some View {
        modifier(HangingActionLabel(title: title, isFocused: isFocused))
    }
}

/// See ``SwiftUI/View/hangingActionLabel(_:isFocused:)``.
private struct HangingActionLabel: ViewModifier {
    @Environment(\.theme) private var theme

    let title: String
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            // The label hangs below the circle as an overlay so its width never
            // participates in layout — the control's footprint is always just
            // the circle, and a state change ("Mark Watched" → "Watched") can't
            // shift the row. Faded rather than conditionally inserted so gaining
            // focus doesn't restructure the view and unsettle the focus engine.
            .overlay(alignment: .bottom) {
                label
                    // Report the label's bottom as its own top minus the gap, so
                    // aligning that "bottom" with the circle's bottom hangs the
                    // label one gap below the circle.
                    .alignmentGuide(.bottom) { $0[.top] - SpacingTokens.sm }
            }
        #if os(tvOS)
            .animation(theme.animation, value: isFocused)
        #else
            // Gaze never reaches the app, so the label can't fade itself the way
            // it does on tvOS. The app composes the effect below and the system
            // runs it; this puts that effect in a group with the control, so
            // looking anywhere at the circle reveals the label beneath it.
            .hoverEffectGroup()
        #endif
    }

    private var label: some View {
        Text(title)
            .jsStyle(.caption)
            .foregroundStyle(theme.secondary)
            .fixedSize()
        #if os(tvOS)
            .opacity(isFocused ? 1 : 0)
        #else
            // The effect sets both phases, so the label is hidden at rest and
            // never needs an `opacity` of its own.
            .hoverEffect { effect, isActive, _ in
                effect.animation(theme.animation) { $0.opacity(isActive ? 1 : 0) }
            }
        #endif
    }
}

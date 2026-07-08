import SwiftUI

/// An icon-only, circular action button that reveals its text label beneath the
/// circle while focused — keeping the action lockup compact when idle (tvOS).
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
        action: @escaping () -> Void
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
                .font(theme.jsHeadline)
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
        // The label hangs below the circle as an overlay so its width never
        // participates in layout — the button's footprint is always just the
        // circle, and a state change ("Mark Watched" → "Watched") can't shift
        // the row. Faded rather than conditionally inserted so gaining focus
        // doesn't restructure the view and unsettle the focus engine.
        .overlay(alignment: .bottom) {
            Text(title)
                .font(theme.jsCaption)
                .foregroundStyle(theme.secondary)
                .fixedSize()
                .opacity(isFocused ? 1 : 0)
                // Report the label's bottom as its own top minus the gap, so
                // aligning that "bottom" with the circle's bottom hangs the
                // label one gap below the circle.
                .alignmentGuide(.bottom) { $0[.top] - SpacingTokens.sm }
        }
        .animation(theme.animation, value: isFocused)
    }
}

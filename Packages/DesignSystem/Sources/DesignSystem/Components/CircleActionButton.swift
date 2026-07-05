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
        VStack(spacing: SpacingTokens.sm) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(theme.jsHeadline)
                    // Focus lifts the glass circle to a light platter; the
                    // theme's light tints wash out there, so swap to the
                    // on-platter color (or the caller's override).
                    .foregroundStyle(isFocused ? (focusedTint ?? theme.onPlatter) : tint)
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .focused($isFocused)
            .disabled(!isEnabled)

            // Reserve the label's space at all times (opacity, not conditional
            // insertion) so gaining focus doesn't shift the layout and unsettle
            // the focus engine.
            Text(title)
                .font(theme.jsCaption)
                .foregroundStyle(theme.secondary)
                .opacity(isFocused ? 1 : 0)
        }
        .animation(theme.animation, value: isFocused)
    }
}

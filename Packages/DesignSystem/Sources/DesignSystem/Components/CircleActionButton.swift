import SwiftUI

/// An icon-only, circular action button that reveals its text label beneath the
/// circle while focused — keeping the action lockup compact when idle (tvOS).
public struct CircleActionButton: View {
    private let systemImage: String
    private let title: String
    private let tint: Color
    private let isEnabled: Bool
    private let action: () -> Void

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    public init(
        systemImage: String,
        title: String,
        tint: Color,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        VStack(spacing: SpacingTokens.sm) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(theme.jsHeadline)
                    .foregroundStyle(tint)
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

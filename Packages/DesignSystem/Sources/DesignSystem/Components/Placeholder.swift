import SwiftUI

/// A placeholder view for components under development
/// Use this to represent components that will be implemented later
public struct ComponentPlaceholder: View {
    let name: String
    let icon: String

    @Environment(\.theme) private var theme

    public init(name: String, icon: String = "puzzlepiece.fill") {
        self.name = name
        self.icon = icon
    }

    public var body: some View {
        VStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(theme.secondary)

            Text(name)
                .font(.jsTitle)
                .foregroundStyle(theme.primary)

            Text("Coming Soon")
                .font(.jsCaption)
                .foregroundStyle(theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
    }
}

#Preview {
    ComponentPlaceholder(name: "Media Card")
        .withThemeEnvironment()
}

import SwiftUI
import DesignSystem

/// Search screen for finding media
struct SearchView: View {
    @Environment(\.theme) private var theme
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: SpacingTokens.lg) {
                // Search placeholder
                VStack(spacing: SpacingTokens.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.secondary)

                    Text("Search Your Library")
                        .font(.jsHeadline)
                        .foregroundStyle(theme.primary)

                    Text("Find movies, shows, and more")
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background)
            .navigationTitle("Search")
        }
    }
}

#Preview {
    SearchView()
        .withThemeEnvironment()
}

import SwiftUI
import DesignSystem

/// Home screen showing personalized content
/// Displays continue watching, recently added, and recommendations
struct HomeView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    // Hero Section
                    heroSection

                    // Continue Watching
                    section(title: "Continue Watching", icon: "play.circle.fill")

                    // Recently Added
                    section(title: "Recently Added", icon: "sparkles")

                    // Recommendations
                    section(title: "Recommended for You", icon: "star.fill")
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
                .padding(.vertical, SpacingTokens.lg)
            }
            .background(theme.background)
            .navigationTitle("Home")
        }
    }

    private var heroSection: some View {
        RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
            .fill(theme.surface)
            .frame(height: 400)
            .overlay {
                VStack {
                    Image(systemName: "film.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.secondary)

                    Text("Featured Content")
                        .font(.jsHeadline)
                        .foregroundStyle(theme.primary)
                        .padding(.top, SpacingTokens.md)

                    Text("Connect to a Jellyfin server to see your media")
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)
                        .padding(.top, SpacingTokens.xs)
                }
            }
    }

    private func section(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            // Section Header
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: icon)
                    .foregroundStyle(theme.accent)

                Text(title)
                    .font(.jsHeadline)
                    .foregroundStyle(theme.primary)
            }

            // Placeholder Cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpacingTokens.cardGap) {
                    ForEach(0..<5) { index in
                        placeholderCard(index: index)
                    }
                }
            }
        }
    }

    private func placeholderCard(index: Int) -> some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius)
            .fill(theme.surface)
            .frame(width: 200, height: 300)
            .overlay {
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(theme.tertiary)

                    Text("Media \(index + 1)")
                        .font(.jsCaption)
                        .foregroundStyle(theme.secondary)
                        .padding(.top, SpacingTokens.xs)
                }
            }
    }
}

#Preview {
    HomeView()
        .withThemeEnvironment()
}

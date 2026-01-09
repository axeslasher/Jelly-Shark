import SwiftUI
import JellyfinKit
import DesignSystem

/// Detail view for a media item
/// Shows full information, play button, and related content
public struct MediaDetailView: View {
    @Environment(\.theme) private var theme

    let item: MediaItem

    public init(item: MediaItem) {
        self.item = item
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                // Hero Section
                heroSection

                // Metadata
                metadataSection

                // Overview
                if let overview = item.overview {
                    overviewSection(overview)
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .background(theme.background)
        .navigationTitle(item.name)
    }

    private var heroSection: some View {
        RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
            .fill(theme.surface)
            .frame(height: 500)
            .overlay {
                VStack(spacing: SpacingTokens.lg) {
                    // Placeholder poster
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(theme.surfaceElevated)
                        .frame(width: 200, height: 300)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 48))
                                .foregroundStyle(theme.tertiary)
                        }

                    // Title
                    Text(item.name)
                        .font(.jsDisplay)
                        .foregroundStyle(theme.primary)

                    // Play Button
                    Button(action: {}) {
                        HStack(spacing: SpacingTokens.sm) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.jsTitle)
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, SpacingTokens.xl)
                        .padding(.vertical, SpacingTokens.md)
                        .background(theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    private var metadataSection: some View {
        HStack(spacing: SpacingTokens.lg) {
            if let year = item.productionYear {
                metadataItem(value: String(year), label: "Year")
            }

            if let runtime = item.formattedRuntime {
                metadataItem(value: runtime, label: "Runtime")
            }

            if let rating = item.communityRating {
                metadataItem(value: String(format: "%.1f", rating), label: "Rating")
            }

            if let officialRating = item.officialRating {
                metadataItem(value: officialRating, label: "Rated")
            }
        }
    }

    private func metadataItem(value: String, label: String) -> some View {
        VStack(spacing: SpacingTokens.xs) {
            Text(value)
                .font(.jsTitle)
                .foregroundStyle(theme.primary)

            Text(label)
                .font(.jsCaption)
                .foregroundStyle(theme.secondary)
        }
        .padding(.horizontal, SpacingTokens.md)
        .padding(.vertical, SpacingTokens.sm)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }

    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            Text("Overview")
                .font(.jsHeadline)
                .foregroundStyle(theme.primary)

            Text(overview)
                .font(.jsBody)
                .foregroundStyle(theme.secondary)
                .lineSpacing(4)
        }
    }
}

#Preview {
    NavigationStack {
        MediaDetailView(
            item: MediaItem(
                id: "preview-1",
                name: "Example Movie",
                type: .movie,
                overview: "This is an example movie with a longer description to show how the overview section looks when there's a substantial amount of text to display.",
                productionYear: 2024,
                runTimeTicks: 72_000_000_000,
                communityRating: 8.5,
                officialRating: "PG-13"
            )
        )
    }
    .withThemeEnvironment()
}

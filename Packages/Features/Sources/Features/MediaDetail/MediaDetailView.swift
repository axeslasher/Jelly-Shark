import SwiftUI
import JellyfinKit
import DesignSystem

/// Detail view for a media item
/// Shows full information, play button, and related content
public struct MediaDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    @State private var isPresentingPlayer = false

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
        #if os(macOS)
        .sheet(isPresented: $isPresentingPlayer) {
            if let client = session.client {
                PlaybackContainerView(client: client, item: item)
            }
        }
        #else
        .fullScreenCover(isPresented: $isPresentingPlayer) {
            if let client = session.client {
                PlaybackContainerView(client: client, item: item)
            }
        }
        #endif
    }

    private var heroSection: some View {
        ArtworkImage(url: session.client?.backdropURL(for: item))
            .frame(maxWidth: .infinity)
            .frame(height: 500)
            .overlay {
                // Scrim so the title and button keep contrast over any backdrop
                theme.background.opacity(0.55)
            }
            .overlay {
                VStack(spacing: SpacingTokens.lg) {
                    // Poster
                    ArtworkImage(url: session.client?.posterURL(for: item))
                        .frame(width: 200, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

                    // Title
                    Text(item.name)
                        .font(.jsDisplay)
                        .foregroundStyle(theme.primary)

                    // Play Button
                    Button {
                        isPresentingPlayer = true
                    } label: {
                        HStack(spacing: SpacingTokens.sm) {
                            Image(systemName: "play.fill")
                            Text(item.hasProgress ? "Resume" : "Play")
                        }
                        .font(.jsTitle)
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, SpacingTokens.xl)
                        .padding(.vertical, SpacingTokens.md)
                        .background(theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.client == nil)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
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
    .environment(AppSession())
}

import SwiftUI
import JellyfinKit
import DesignSystem

/// Home screen showing personalized content
/// Displays a featured hero, continue watching, and recently added
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var connection

    @State private var resumeItems: [MediaItem] = []
    @State private var latestItems: [MediaItem] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    // Hero Section
                    heroSection

                    // Continue Watching
                    if !resumeItems.isEmpty {
                        section(title: "Continue Watching", icon: "play.circle.fill") {
                            ForEach(resumeItems) { item in
                                itemLink(for: item) {
                                    landscapeCard(for: item)
                                }
                            }
                        }
                    }

                    // Recently Added
                    if !latestItems.isEmpty {
                        section(title: "Recently Added", icon: "sparkles") {
                            ForEach(latestItems) { item in
                                itemLink(for: item) {
                                    posterCard(for: item)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
                .padding(.vertical, SpacingTokens.lg)
            }
            .background(theme.background)
            .navigationTitle("Home")
            .task(id: session.isConnected) {
                await loadContent()
            }
        }
    }

    // MARK: - Hero

    private var heroItem: MediaItem? {
        guard let client = session.client else { return nil }
        return (resumeItems + latestItems).first { client.backdropURL(for: $0) != nil }
    }

    @ViewBuilder
    private var heroSection: some View {
        if let client = session.client, let item = heroItem {
            NavigationLink {
                MediaDetailView(item: item)
            } label: {
                ArtworkImage(url: client.backdropURL(for: item))
                    .frame(maxWidth: .infinity)
                    .frame(height: 400)
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: theme.background.opacity(0.85), location: 0),
                                .init(color: .clear, location: 0.5),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                            Text(item.name)
                                .font(.jsHeadline)
                                .foregroundStyle(theme.primary)

                            if let year = item.productionYear {
                                Text(String(year))
                                    .font(.jsBody)
                                    .foregroundStyle(theme.secondary)
                            }
                        }
                        .padding(SpacingTokens.lg)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(.plain)
            #endif
        } else {
            placeholderHero
        }
    }

    private var placeholderHero: some View {
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

                    Text(heroSubtitle)
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)
                        .padding(.top, SpacingTokens.xs)
                }
            }
    }

    private var heroSubtitle: String {
        if connection.state == .connected, let user = connection.connectedUser {
            return "Signed in as \(user.name)"
        }
        return "Connect to a Jellyfin server to see your media"
    }

    // MARK: - Sections

    private func section(title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            // Section Header
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: icon)
                    .foregroundStyle(theme.accent)

                Text(title)
                    .font(.jsHeadline)
                    .foregroundStyle(theme.primary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                    content()
                }
            }
        }
    }

    private func itemLink(for item: MediaItem, @ViewBuilder label: () -> some View) -> some View {
        NavigationLink {
            MediaDetailView(item: item)
        } label: {
            label()
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Cards

    private func posterCard(for item: MediaItem) -> some View {
        VStack(spacing: SpacingTokens.xs) {
            ArtworkImage(url: session.client?.posterURL(for: item))
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

            Text(item.name)
                .font(.jsCaption)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(width: 200)
        }
    }

    private func landscapeCard(for item: MediaItem) -> some View {
        VStack(spacing: SpacingTokens.xs) {
            ArtworkImage(url: session.client?.landscapeURL(for: item))
                .frame(width: 320, height: 180)
                .overlay(alignment: .bottomLeading) {
                    if let progress = item.progressPercentage {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 320 * progress, height: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

            Text(item.episodeDisplayTitle ?? item.name)
                .font(.jsCaption)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(width: 320)
        }
    }

    // MARK: - Data

    private func loadContent() async {
        guard let client = session.client, session.isConnected else {
            resumeItems = []
            latestItems = []
            return
        }

        // Failures degrade to empty sections rather than blocking the screen
        async let resume = client.getResumeItems(limit: 12)
        async let latest = client.getLatestItems(libraryId: nil, limit: 16)

        resumeItems = (try? await resume) ?? []
        latestItems = (try? await latest) ?? []
    }
}

#Preview {
    HomeView()
        .withThemeEnvironment()
        .environment(AppSession())
        .environment(ServerConnectionViewModel())
}

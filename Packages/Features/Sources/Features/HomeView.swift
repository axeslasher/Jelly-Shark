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
    @State private var belowFold = false

    // No NavigationStack here: RootView owns each tab's stack (with a path
    // binding) so it can pop to root before a tab switch — see RootView's
    // `tabSelection` for the tvOS bug this works around.
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                // Hero Section
                heroSection
                    .onScrollVisibilityChange { visible in
                        withAnimation(theme.animation) {
                            belowFold = !visible
                        }
                    }

                // Continue Watching
                if !resumeItems.isEmpty {
                    ContentShelf("Continue Watching", icon: "play.circle.fill") {
                        ForEach(resumeItems) { item in
                            item.landscapeShelfItem(client: session.client)
                        }
                    }
                }

                // Recently Added
                if !latestItems.isEmpty {
                    ContentShelf("Recently Added", icon: "sparkles") {
                        ForEach(latestItems) { item in
                            item.posterShelfItem(client: session.client)
                        }
                    }
                }
            }
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .background(alignment: .top) { heroBackground }
        .background(theme.background)
        .task(id: session.isConnected) {
            await loadContent()
        }
    }

    // MARK: - Hero

    private var heroItem: MediaItem? {
        guard let client = session.client else { return nil }
        return (resumeItems + latestItems).first { client.backdropURL(for: $0) != nil }
    }

    /// Full-bleed backdrop behind the above-the-fold content. Masked with a
    /// gradient so it melts into the background, and faded out once the hero
    /// scrolls away (`belowFold`).
    @ViewBuilder
    private var heroBackground: some View {
        if let client = session.client, let item = heroItem, !belowFold {
            ArtworkImage(url: client.backdropURL(for: item), blurHash: item.backdropBlurHash)
                .frame(height: 1080)
                .frame(maxWidth: .infinity)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.6),
                            .init(color: .clear, location: 0.9),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var heroSection: some View {
        if let item = heroItem {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                Spacer(minLength: 420)

                Text(item.name)
                    .jsStyle(.display)
                    .foregroundStyle(theme.primary)

                if let year = item.productionYear {
                    Text(String(year))
                        .jsStyle(.title)
                        .foregroundStyle(theme.secondary)
                }

                NavigationLink(value: item) {
                    Label("View Details", systemImage: "info.circle")
                }
                .padding(.top, SpacingTokens.sm)
                .padding(.bottom, SpacingTokens.lg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpacingTokens.screenPadding)
        } else {
            placeholderHero
                .padding(.horizontal, SpacingTokens.screenPadding)
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
                        .jsStyle(.headline)
                        .foregroundStyle(theme.primary)
                        .padding(.top, SpacingTokens.md)

                    Text(heroSubtitle)
                        .jsStyle(.body)
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
    NavigationStack {
        HomeView()
    }
    .withThemeEnvironment()
    .environment(AppSession())
    .environment(ServerConnectionViewModel())
}

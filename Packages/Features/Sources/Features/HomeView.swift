import DesignSystem
import JellyfinKit
import SwiftUI

/// Home screen showing personalized content
/// Displays a featured hero, continue watching, and recently added
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var connection

    @State private var resumeItems: [MediaItem] = []
    @State private var latestItems: [MediaItem] = []
    @State private var genreCards: [GenreCard] = []
    @State private var belowFold = false

    /// How many genre cards the Browse by Genre shelf shows.
    private let genreCardLimit = 12

    /// No NavigationStack here: RootView owns each tab's stack (with a path
    /// binding) so it can pop to root before a tab switch — see RootView's
    /// `tabSelection` for the tvOS bug this works around.
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

                // Browse by Genre
                if !genreCards.isEmpty {
                    ContentShelf("Browse by Genre", icon: "theatermasks.fill") {
                        ForEach(genreCards) { card in
                            GenreShelfItem(
                                title: card.name,
                                backdropURL: card.backdropURL,
                                blurHash: card.blurHash,
                                value: GenreFilter(library: card.library, genre: card.name),
                            )
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
            await loadGenres()
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
                        endPoint: .bottom,
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

        resumeItems = await (try? resume) ?? []
        latestItems = await (try? latest) ?? []
    }

    /// The library whose genres the shelf browses. Genre filtering is
    /// library-scoped, so the shelf targets one library — preferring a movies
    /// library (the most genre-rich), else the first available.
    private var genreSourceLibrary: Library? {
        let libraries = connection.libraries
        return libraries.first { $0.collectionType == .movies } ?? libraries.first
    }

    /// Build the genre cards for a library: fetch the genres present, then pick
    /// a random backdrop for each (concurrently). Loaded once per connection —
    /// genres are stable, and the per-genre fetches shouldn't repeat on every
    /// return to Home. Any failure degrades to an empty shelf.
    private func loadGenres() async {
        guard let client = session.client, session.isConnected else {
            genreCards = []
            return
        }
        // Already populated (a return to Home, not a fresh connection) — keep
        // the existing cards rather than re-running the per-genre fetches.
        guard genreCards.isEmpty, let library = genreSourceLibrary else { return }

        guard let options = try? await client.getLibraryFilterOptions(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes,
        ), !options.genres.isEmpty else {
            genreCards = []
            return
        }

        let genres = Array(options.genres.prefix(genreCardLimit))
        let backdrops = await withTaskGroup(of: (Int, URL?, String?).self) { group in
            for (index, genre) in genres.enumerated() {
                group.addTask {
                    let backdrop = await representativeBackdrop(
                        client: client, library: library, genre: genre,
                    )
                    return (index, backdrop?.url, backdrop?.blurHash)
                }
            }
            var byIndex: [Int: (URL?, String?)] = [:]
            for await (index, url, hash) in group {
                byIndex[index] = (url, hash)
            }
            return byIndex
        }

        genreCards = genres.enumerated().map { index, genre in
            GenreCard(
                name: genre,
                library: library,
                backdropURL: backdrops[index]?.0 ?? nil,
                blurHash: backdrops[index]?.1 ?? nil,
            )
        }
    }
}

/// One card in the Browse by Genre shelf: the genre name, the library it
/// filters, and a representative backdrop.
private struct GenreCard: Identifiable {
    let name: String
    let library: Library
    let backdropURL: URL?
    let blurHash: String?

    var id: String {
        name
    }
}

/// Pick a random item's backdrop to represent a genre. Fetches a small page of
/// that genre (there's no server-side random sort) and chooses randomly among
/// the items that actually have a backdrop, so a future "refresh" affordance can
/// just re-run this for one card. Returns nil when the genre has no artwork.
private func representativeBackdrop(
    client: any JellyfinClientProtocol,
    library: Library,
    genre: String,
) async -> (url: URL, blurHash: String?)? {
    guard let page = try? await client.getLibraryItems(
        libraryId: library.id,
        itemTypes: library.collectionType?.gridItemTypes,
        query: LibraryQuery(genres: [genre]),
        limit: 24,
        startIndex: 0,
    ) else { return nil }

    let withBackdrop = page.items.filter { client.backdropURL(for: $0) != nil }
    guard let item = withBackdrop.randomElement(),
          let url = client.backdropURL(for: item)
    else { return nil }
    return (url, item.backdropBlurHash)
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .withThemeEnvironment()
    .environment(AppSession())
    .environment(ServerConnectionViewModel())
}

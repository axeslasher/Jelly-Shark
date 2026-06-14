import SwiftUI
import JellyfinKit
import DesignSystem

/// Detail view for a media item.
///
/// Mirrors `HomeView`'s hero treatment: a full-bleed backdrop that melts into the
/// background behind a left-aligned title, metadata row, and Play button, followed
/// by the overview and Cast & Crew / More Like This shelves.
public struct MediaDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    @State private var detailedItem: MediaItem?
    @State private var similarItems: [MediaItem] = []
    @State private var belowFold = false
    @State private var isPresentingPlayer = false

    let item: MediaItem

    public init(item: MediaItem) {
        self.item = item
    }

    /// The passed-in stub renders instantly; the detailed fetch (which carries
    /// cast & crew) upgrades it once it lands.
    private var displayItem: MediaItem { detailedItem ?? item }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                heroSection
                    .onScrollVisibilityChange { visible in
                        withAnimation(theme.animation) {
                            belowFold = !visible
                        }
                    }

                

                if let client = session.client,
                   let people = displayItem.people, !people.isEmpty {
                    ContentShelf("Cast & Crew", icon: "person.2.fill") {
                        ForEach(people) { member in
                            CastCard(
                                url: client.headshotURL(for: member),
                                name: member.name,
                                role: member.role ?? member.kind
                            )
                        }
                    }
                }

                if !similarItems.isEmpty {
                    ContentShelf("More Like This", icon: "rectangle.stack.fill") {
                        ForEach(similarItems) { item in
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
        .task(id: item.id) {
            await loadContent()
        }
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

    // MARK: - Hero

    /// Full-bleed backdrop behind the above-the-fold content. Masked with a
    /// gradient so it melts into the background, and faded out once the hero
    /// scrolls away (`belowFold`).
    @ViewBuilder
    private var heroBackground: some View {
        if let client = session.client,
           let url = client.backdropURL(for: displayItem), !belowFold {
            ArtworkImage(url: url)
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

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Spacer(minLength: 320)

            titleTreatment

            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.jsTitle)
                    .foregroundStyle(theme.secondary)
            }
            if let overview = displayItem.overview {
                overviewSection(overview)
                    .padding(.top, SpacingTokens.md)
                    //.frame(idealWidth: 380, maxWidth: 500)
            }
            
            
            playButton
                .padding(.top, SpacingTokens.lg)
                .padding(.bottom, SpacingTokens.lg)
                
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        
    }

    /// The item's logo if one exists, falling back to the title text. Rendered
    /// with `AsyncImage` (not `ArtworkImage`) so the logo's transparency is
    /// preserved instead of being boxed in by a surface-colored base.
    @ViewBuilder
    private var titleTreatment: some View {
        if let client = session.client, let url = client.logoURL(for: displayItem) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        // Size the logo into its box, then pin that box to the
                        // leading edge so logos of any width stay left-aligned.
                        .frame(maxWidth: 500, maxHeight: 160, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    titleText
                }
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(displayItem.name)
            .font(.jsDisplay)
            .foregroundStyle(theme.primary)
    }

    /// Inline "year · runtime · rating · rated" row, omitting any missing field.
    private var metadataLine: String {
        var parts: [String] = []
        if let year = displayItem.productionYear { parts.append(String(year)) }
        if let runtime = displayItem.formattedRuntime { parts.append(runtime) }
        if let rating = displayItem.communityRating { parts.append(String(format: "%.1f", rating)) }
        if let officialRating = displayItem.officialRating { parts.append(officialRating) }
        return parts.joined(separator: " · ")
    }

    private var playButton: some View {
        Button {
            isPresentingPlayer = true
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: "play.fill")
                Text(displayItem.hasProgress ? "Resume" : "Play")
            }
            .font(.jsTitle)
            .buttonStyle(.glass(.clear))
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
        }
        .buttonStyle(.glass)
        .disabled(session.client == nil)
    }

    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            //Text("Overview")
            //    .font(.jsHeadline)
            //    .foregroundStyle(theme.primary)

            Text(overview)
                .font(.jsBody)
                .foregroundStyle(theme.primary)
                .lineSpacing(4)
        }
        //.padding(.horizontal, SpacingTokens.screenPadding)
    }

    // MARK: - Data

    private func loadContent() async {
        guard let client = session.client else { return }

        // Failures degrade gracefully: keep the passed-in stub, skip the shelf.
        detailedItem = (try? await client.getMediaItem(itemId: item.id)) ?? item
        similarItems = (try? await client.getSimilarItems(itemId: item.id, limit: 12)) ?? []
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

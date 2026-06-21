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
    /// gradient so it melts into the background. Rather than disappearing once the
    /// hero scrolls away (`belowFold`), it stays mounted and dims + blurs into a
    /// faint atmospheric wash behind the shelves.
    @ViewBuilder
    private var heroBackground: some View {
        if let client = session.client,
           let url = client.backdropURL(for: displayItem) {
            ArtworkImage(url: url)
                .overlay {
                        // Build the gradient material by filling an area with a material, and
                        // then masking that area using a linear gradient.
                        Rectangle()
                            .fill(.regularMaterial)
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0.25),
                                        .init(color: .black.opacity(belowFold ? 1 : 0.3), location: 0.375),
                                        .init(color: .black.opacity(belowFold ? 1 : 0), location: 0.5)
                                    ],
                                    startPoint: .bottom, endPoint: .top
                                )
                            }
                }
                .opacity(belowFold ? 0.3 : 1)
                .blur(radius: belowFold ? 20 : 0)
                .ignoresSafeArea()
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Spacer(minLength: 320)

            titleTreatment

            if hasMetadata {
                metadataRow
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
                        .frame(maxWidth: 500, maxHeight: 300, alignment: .leading)
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

    /// Whether any metadata field is present, so the hero can skip the row entirely
    /// rather than rendering an empty stack.
    private var hasMetadata: Bool {
        displayItem.productionYear != nil
            || displayItem.formattedRuntime != nil
            || displayItem.communityRating != nil
            || displayItem.officialRating != nil
    }

    /// Inline year · runtime · rating · rated row, each with an SF Symbol, omitting
    /// any missing field. The official rating renders as a bordered certificate badge.
    private var metadataRow: some View {
        HStack(alignment: .center, spacing: SpacingTokens.md) {
            if let year = displayItem.productionYear {
                Label(String(year), systemImage: "calendar")
            }
            if let runtime = displayItem.formattedRuntime {
                Label(runtime, systemImage: "clock")
            }
            if let rating = displayItem.communityRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
            }
            if let officialRating = displayItem.officialRating {
                Text(officialRating)
                    .padding(.horizontal, SpacingTokens.sm)
                    .padding(.vertical, SpacingTokens.xs)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.secondary, lineWidth: 2)
                    )
            }
        }
        .font(.jsTitle)
        .foregroundStyle(theme.secondary)
        .labelStyle(MetadataLabelStyle(spacing: SpacingTokens.xs))
        
    }

    private var playButton: some View {
        Button {
            isPresentingPlayer = true
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: "play.fill")
                Text(displayItem.hasProgress ? "Resume" : "Play")
            }
            .font(.jsHeadline)
            .buttonStyle(.glass(.clear))
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
        }
        .buttonStyle(.glass)
        .disabled(session.client == nil)
    }

    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            Text(overview)
                .font(.jsOverview)
                .foregroundStyle(theme.primary)
                .lineSpacing(4)
        }
    }

    // MARK: - Data

    private func loadContent() async {
        guard let client = session.client else { return }

        // Failures degrade gracefully: keep the passed-in stub, skip the shelf.
        detailedItem = (try? await client.getMediaItem(itemId: item.id)) ?? item
        similarItems = (try? await client.getSimilarItems(itemId: item.id, limit: 12)) ?? []
    }
}

/// A `Label` layout with explicit icon↔title spacing, since `Label` exposes none.
private struct MetadataLabelStyle: LabelStyle {
    var spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
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

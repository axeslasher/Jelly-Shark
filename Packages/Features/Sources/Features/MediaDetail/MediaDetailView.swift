import DesignSystem
import JellyfinKit
import SwiftUI

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
    @State private var isPresentingOverview = false

    /// Optimistic local overrides for the watched / favorite toggles. While `nil`,
    /// the buttons reflect Jellyfin's fetched `userData`; a tap sets the override
    /// immediately and is cleared/reverted based on the server response.
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    /// Watched state shown by the button: the pending optimistic value if any,
    /// otherwise Jellyfin's stored status for this item.
    private var isPlayed: Bool {
        playedOverride ?? displayItem.userData?.played ?? false
    }

    /// Favorite state shown by the button: optimistic value if any, otherwise
    /// Jellyfin's stored status.
    private var isFavorite: Bool {
        favoriteOverride ?? displayItem.userData?.isFavorite ?? false
    }

    let item: MediaItem

    public init(item: MediaItem) {
        self.item = item
    }

    /// The passed-in stub renders instantly; the detailed fetch (which carries
    /// cast & crew) upgrades it once it lands.
    private var displayItem: MediaItem {
        detailedItem ?? item
    }

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
                   let people = displayItem.people, !people.isEmpty
                {
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
            .padding(.vertical, SpacingTokens.md)
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
        #if os(macOS)
        .sheet(isPresented: $isPresentingOverview) {
            overviewOverlay
        }
        #else
        .fullScreenCover(isPresented: $isPresentingOverview) {
            overviewOverlay
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
           let url = client.backdropURL(for: displayItem)
        {
            ArtworkImage(url: url)
                .overlay {
                    // Bottom-edge "melt": a material masked by a gradient so the
                    // hero text reads against the backdrop. This is only needed
                    // above the fold — it fades out entirely once scrolled, so
                    // the below-fold state is purely the dim + blur wash, exactly
                    // matching `overviewOverlay`.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.25),
                                    .init(color: .black.opacity(0.3), location: 0.375),
                                    .init(color: .black.opacity(0), location: 0.5)
                                ],
                                startPoint: .bottom, endPoint: .top
                            )
                        }
                        .opacity(belowFold ? 0 : 1)
                }
                .opacity(belowFold ? 0.3 : 1)
                .blur(radius: belowFold ? 20 : 0)
                .ignoresSafeArea()
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xs) {
            Spacer(minLength: 280)
            titleTreatment

            HStack(alignment: .top, spacing: SpacingTokens.xl) {
                VStack(alignment: .leading, spacing: SpacingTokens.md) {
                    if hasMetadata {
                        metadataRow
                    }

                    HStack(alignment: .top, spacing: SpacingTokens.sm) {
                        playButton
                        secondaryActions
                    }
                    
                }

                if displayItem.overview != nil || displayItem.tagline != nil {
                    overviewSection
                }
            }
            .padding(.top, SpacingTokens.lg)
            // .padding(.bottom, SpacingTokens.sm)
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
                        // Fixed box reserves a consistent logo footprint for every
                        // item; scaledToFit letterboxes the logo inside it and
                        // bottomLeading pins it so the content below never shifts.
                        .frame(width: 480, height: 280, alignment: .bottomLeading)
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
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
                    .padding(.horizontal, SpacingTokens.xs)
                    .padding(.vertical, SpacingTokens.xxs)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.secondary, lineWidth: 2)
                    )
            }
        }
        .font(.jsBody)
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
        .buttonStyle(.glass(.clear))
        .disabled(session.client == nil)
    }

    /// Secondary actions beneath Play: icon-only circular toggles for watched
    /// state and favorite. Each reveals its label beneath the circle while
    /// focused. Both flip optimistically and revert if the server call fails.
    private var secondaryActions: some View {
        HStack(alignment: .top, spacing: SpacingTokens.sm) {
            CircleActionButton(
                systemImage: isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                title: isPlayed ? "Watched" : "Mark Watched",
                tint: theme.primary,
                isEnabled: session.client != nil
            ) {
                Task { await togglePlayed() }
            }

            CircleActionButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                title: isFavorite ? "Favorited" : "Favorite",
                tint: isFavorite ? theme.accent : theme.primary,
                isEnabled: session.client != nil
            ) {
                Task { await toggleFavorite() }
            }
        }
    }

    /// Truncated overview. The description truncates on
    /// the page and lives in a `.plain` Button that reveals the full text in a
    /// full-screen overlay.
    private var overviewSection: some View {
        Button {
            isPresentingOverview = true
        } label: {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                if let tagline = displayItem.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.jsHeadline)
                        .foregroundStyle(theme.primary)
                        .lineLimit(2)
                        
                }
                if let overview = displayItem.overview {
                    Text(overview)
                        .font(.jsOverview)
                        .foregroundStyle(theme.secondary)
                        .lineSpacing(4)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// Full-screen reading view for the overview, layered over the same dimmed,
    /// blurred backdrop used by the hero once it scrolls below the fold.
    private var overviewOverlay: some View {
        ZStack {
            theme.background
            if let client = session.client,
               let url = client.backdropURL(for: displayItem)
            {
                ArtworkImage(url: url)
                    .opacity(0.3)
                    .blur(radius: 20)
            }
            VStack(alignment: .center, spacing: SpacingTokens.md) {
                if let tagline = displayItem.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.jsHeadline)
                        .foregroundStyle(theme.primary)
                }
                if let overview = displayItem.overview {
                    Text(overview)
                        .font(.jsTitle)
                        .foregroundStyle(theme.primary)
                        .lineSpacing(4)
                }
            }
            .frame(maxWidth: 800)
        }
        .ignoresSafeArea()
    }

    // MARK: - Data

    private func loadContent() async {
        guard let client = session.client else { return }

        // Failures degrade gracefully: keep the passed-in stub, skip the shelf.
        detailedItem = (try? await client.getMediaItem(itemId: item.id)) ?? item
        similarItems = (try? await client.getSimilarItems(itemId: item.id, limit: 12)) ?? []
    }

    /// Optimistically flip the watched state, then persist; revert on failure.
    private func togglePlayed() async {
        guard let client = session.client else { return }
        let target = !isPlayed
        withAnimation(theme.animation) { playedOverride = target }
        do {
            if target {
                try await client.markPlayed(itemId: displayItem.id)
            } else {
                try await client.markUnplayed(itemId: displayItem.id)
            }
        } catch {
            withAnimation(theme.animation) { playedOverride = !target }
        }
    }

    /// Optimistically flip the favorite state, then persist; revert on failure.
    private func toggleFavorite() async {
        guard let client = session.client else { return }
        let target = !isFavorite
        withAnimation(theme.animation) { favoriteOverride = target }
        do {
            if target {
                try await client.markFavorite(itemId: displayItem.id)
            } else {
                try await client.unmarkFavorite(itemId: displayItem.id)
            }
        } catch {
            withAnimation(theme.animation) { favoriteOverride = !target }
        }
    }
}

/// An icon-only, circular action button that reveals its text label beneath the
/// circle while focused — keeping the action lockup compact when idle (tvOS).
private struct CircleActionButton: View {
    @Environment(\.theme) private var theme

    let systemImage: String
    let title: String
    var tint: Color
    var isEnabled: Bool = true
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: SpacingTokens.sm) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.jsHeadline)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.glass(.clear))
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .focused($isFocused)
            .disabled(!isEnabled)

            // Reserve the label's space at all times (opacity, not conditional
            // insertion) so gaining focus doesn't shift the layout and unsettle
            // the focus engine.
            Text(title)
                .font(.jsCaption)
                .foregroundStyle(theme.secondary)
                .opacity(isFocused ? 1 : 0)
        }
        .animation(theme.animation, value: isFocused)
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

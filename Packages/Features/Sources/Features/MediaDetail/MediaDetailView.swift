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

    /// Continuous scroll progress for the hero treatment: 0 at the top, ramping to
    /// 1 once the backdrop has scrolled `Self.heroFadeDistance` points. Drives the
    /// melt/dim/blur so the transition tracks the scroll instead of snapping after
    /// the hero leaves the screen.
    @State private var scrollProgress: CGFloat = 0

    /// Points of scrolling over which the hero fully transitions to its dimmed,
    /// blurred wash. Smaller = snappier; larger = more gradual.
    private static let heroFadeDistance: CGFloat = 350
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
            // A plain VStack (not LazyVStack): there are only ever three sections,
            // and on tvOS the focus engine can't move focus into — and therefore
            // can't scroll to — a section that a lazy stack hasn't built yet. The
            // per-shelf horizontal scrolls remain lazy on their own.
            VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                heroSection

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
            // Each section (hero, Cast & Crew, More Like This) becomes a snap
            // target so the scroll settles aligned to a section boundary rather
            // than mid-content. Paired with the viewport-tall hero, this gives a
            // clean hero → shelves snap.
            //
            // tvOS is excluded: there scrolling is driven by the focus engine, and
            // `.scrollTargetBehavior` re-aligns the scroll out from under it — which
            // traps focus in the hero. The viewport-tall hero already produces the
            // snap-like jump there. Snapping applies on visionOS / iOS only.
            #if !os(tvOS)
            .scrollTargetLayout()
            #endif
            .padding(.vertical, SpacingTokens.md)
        }
        .scrollClipDisabled()
        #if !os(tvOS)
        .scrollTargetBehavior(.viewAligned)
        #endif
        // Map the live scroll offset to 0...1 so the hero treatment animates with
        // the scroll. `contentOffset.y + contentInsets.top` is 0 at rest and grows
        // as the content scrolls up; no `withAnimation` here — the scroll itself
        // provides the continuity.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scrollProgress = min(max(offset / Self.heroFadeDistance, 0), 1)
        }
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
                    // Bottom-edge "melt", above the fold only (fades out on scroll
                    // so the below-fold state is purely the dim + blur wash that
                    // matches `overviewOverlay`):
                    //   1. a frosted `.ultraThinMaterial`, masked by a gradient so
                    //      it only frosts the lower portion of the backdrop;
                    //   2. a gradient of the page background color on top, so the
                    //      backdrop fades cleanly into the surface beneath the hero
                    //      text — solid at the bottom edge, clearing toward the
                    //      middle.
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0.0),
                                        .init(color: .black.opacity(0.3), location: 0.3),
                                        .init(color: .black.opacity(0), location: 0.6)
                                    ],
                                    startPoint: .bottom, endPoint: .top
                                )
                            }
                        LinearGradient(
                            stops: [
                                .init(color: theme.background, location: 0.0),
                                .init(color: theme.background.opacity(0.6), location: 0.3),
                                .init(color: theme.background.opacity(0), location: 0.6)
                            ],
                            startPoint: .bottom, endPoint: .top
                        )
                    }
                    .opacity(1 - scrollProgress)
                }
                // ── Scroll-transition tuning ─────────────────────────────────
                // All three effects are driven by `scrollProgress` (0 at top → 1
                // after scrolling `heroFadeDistance` pts). Adjust the speed of the
                // whole transition with `heroFadeDistance` (declared up top); tune
                // the *destination* look of each effect here:
                //
                //   • Melt overlay: `1 - scrollProgress` fades the above-fold
                //     gradient/frost out completely. Multiply by < 1 to leave some
                //     melt behind even when fully scrolled.
                //   • Backdrop dim: `0.7` is how much it dims — final opacity is
                //     1 − 0.7 = 0.3. Larger factor = darker wash (e.g. 0.85 → 0.15
                //     remaining); smaller = brighter backdrop while scrolled.
                //   • Blur: `20` is the max blur radius at full scroll. Higher =
                //     softer/foggier wash; 0 disables the blur entirely.
                // ─────────────────────────────────────────────────────────────
                .opacity(1 - 0.7 * scrollProgress)
                .blur(radius: 20 * scrollProgress)
                .ignoresSafeArea()
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.lg) {
            titleTreatment

            HStack(alignment: .top, spacing: SpacingTokens.xl) {
                VStack(alignment: .leading, spacing: SpacingTokens.md) {
                    HStack(alignment: .top, spacing: SpacingTokens.sm) {
                        playButton
                        secondaryActions
                    }
                }
                VStack(alignment: .leading, spacing: SpacingTokens.md) {
                    if displayItem.overview != nil || displayItem.tagline != nil {
                        overviewSection
                        if hasMetadata {
                            metadataRow
                        }
                    }
                }
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    if !directors.isEmpty {
                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(directors.count > 1 ? "Directed by" : "Director")
                                .font(.jsCaption)
                                .foregroundStyle(theme.tertiary)
                                .fontWeight(.bold)
                                .textCase(.uppercase)
                                .tracking(TypographyTokens.Tracking.wide)
                            Text(directors.map(\.name).joined(separator: ", "))
                                .font(.jsBody)
                                .foregroundStyle(theme.secondary)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                        }
                    }
                    if !topCast.isEmpty {
                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text("Starring")
                                .font(.jsCaption)
                                .foregroundStyle(theme.tertiary)
                                .fontWeight(.bold)
                                .textCase(.uppercase)
                                .tracking(TypographyTokens.Tracking.wide)
                            Text(topCast.map(\.name).joined(separator: ", "))
                                .font(.jsBody)
                                .foregroundStyle(theme.secondary)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(width: 250)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, SpacingTokens.md)
        // Reserve a full viewport-height hero and pin the content to the bottom.
        // Anchoring (rather than pushing down with a Spacer) keeps the action row /
        // overview / credits on the same baseline for every item — the logo or
        // title fallback grows upward into the backdrop instead of shoving the rest
        // of the lockup around. Tuning: drop `.vertical` to a fraction via the
        // closure form (e.g. `.containerRelativeFrame(.vertical) { h, _ in h * 0.85 }`)
        // for a shorter hero, or change `.bottom` padding above to lift the lockup.
        .containerRelativeFrame(.vertical, alignment: .bottomLeading)
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

    /// Crew functions that some servers stuff into a person's `role` while still
    /// tagging `kind` as "Actor". Used to recognize crew (and exclude them from
    /// the billed-cast list) regardless of which field carries the credit.
    private static let crewRoles: Set<String> = [
        "Director", "Writer", "Producer",
        "Executive Producer", "Co-Producer", "Co-Executive Producer"
    ]

    /// All credited directors, handling both standard data (`kind == "Director"`)
    /// and servers that report everyone as `kind == "Actor"` with the function in
    /// `role`.
    private var directors: [CastMember] {
        (displayItem.people ?? []).filter { $0.kind == "Director" || $0.role == "Director" }
    }

    /// Top 3 billed cast members, in Jellyfin's listed billing order. Excludes
    /// crew that some servers mislabel as `kind == "Actor"` (via their `role`).
    private var topCast: [CastMember] {
        (displayItem.people ?? [])
            .filter { $0.kind == "Actor" && !(($0.role).map(Self.crewRoles.contains) ?? false) }
            .prefix(3)
            .map { $0 }
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
                    // Ratings badge always uses Zodiak, regardless of the active
                    // theme's font scheme. Falls back to the system font if Zodiak
                    // isn't installed (same behavior as the scheme resolver).
                    .font(.custom(FontFamily.zodiak, fixedSize: TypographyTokens.Size.caption))
                    .fontWeight(.bold)
                    .padding(.horizontal, SpacingTokens.xs)
                    .padding(.vertical, SpacingTokens.xxs)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.tertiary, lineWidth: 2)
                    )
            }
        }
        .font(.jsBody)
        .foregroundStyle(theme.tertiary)
        .fontWeight(.bold)
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

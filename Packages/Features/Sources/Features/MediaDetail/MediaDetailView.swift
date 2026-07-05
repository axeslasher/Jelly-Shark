import DesignSystem
import JellyfinKit
import SwiftUI

/// Detail view for a media item.
///
/// Mirrors `HomeView`'s hero treatment: a full-bleed backdrop that melts into the
/// background behind a left-aligned title, metadata row, and Play button, followed
/// by the overview and Cast & Crew / More Like This shelves.
///
/// Each section is its own `View` struct (not a computed property) so it forms an
/// invalidation boundary: `scrollProgress` changes every scroll tick, but only
/// this thin composing body and the hero backdrop re-evaluate — the shelves'
/// inputs are unchanged, so SwiftUI skips their bodies entirely.
public struct MediaDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    @State private var detailedItem: MediaItem?
    @State private var similarItems: [MediaItem] = []

    /// Credits derived once when the detailed item lands (see `loadContent`),
    /// rather than re-filtering `people` on every body evaluation.
    @State private var directors: [CastMember] = []
    @State private var topCast: [CastMember] = []

    /// Continuous scroll progress for the hero treatment: 0 at the top, ramping to
    /// 1 once the backdrop has scrolled `Self.heroFadeDistance` points. Drives the
    /// melt/dim/blur so the transition tracks the scroll instead of snapping after
    /// the hero leaves the screen.
    @State private var scrollProgress: CGFloat = 0

    /// Points of scrolling over which the hero fully transitions to its dimmed,
    /// blurred wash. Smaller = snappier; larger = more gradual.
    private static let heroFadeDistance: CGFloat = 350

    /// How far (points) the hero lockup drifts as it fades on scroll. Negative =
    /// drifts up (leaves faster); positive = drifts down (lags the scroll and
    /// lingers). Set to 0 for a pure cross-fade with no movement.
    private static let heroScrollDrift: CGFloat = -290

    /// Scroll distance ignored before the hero transition begins. The tvOS focus
    /// engine settles the offset by a few dozen points when focus lands on the
    /// hero's controls (e.g. Play, as the view appears); starting the fade past
    /// that keeps the backdrop crisp until the scroll is a deliberate move
    /// toward the shelves.
    private static let heroFadeThreshold: CGFloat = 60

    /// Which page of the detail view owns focus on tvOS: the hero lockup or the
    /// shelves below it. Scrolling there is focus-driven, so instead of letting
    /// the engine settle at whatever offset barely reveals the focused element,
    /// crossing this boundary snaps the scroll to the matching anchor — top for
    /// the hero, bottom for the shelves (see the `onChange` in `body`). Focus
    /// moves *within* a region don't change it, so nothing re-scrolls.
    private enum FocusRegion: Hashable {
        case hero
        case shelves
    }

    @FocusState private var focusedRegion: FocusRegion?

    /// Handle for the two-anchor snap; only written on tvOS.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    @State private var isPresentingPlayer = false
    @State private var isPresentingOverview = false

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
                MediaDetailHeroSection(
                    item: displayItem,
                    directors: directors,
                    topCast: topCast,
                    isPresentingPlayer: $isPresentingPlayer,
                    isPresentingOverview: $isPresentingOverview
                )
                // Drift the hero lockup as it scrolls, in lockstep with the
                // backdrop's melt/dim/blur. Offset only — no opacity fade: fading
                // the hero to opacity 0 makes its controls unfocusable on tvOS
                // (scrolling is focus movement there), which strands the scroll.
                // Applied here rather than inside HeroSection so the hero's inputs
                // stay unchanged during scroll and its body is skipped.
                .offset(y: scrollProgress * Self.heroScrollDrift)
                #if os(tvOS)
                .focusSection()
                .focused($focusedRegion, equals: .hero)
                #endif

                // Both shelves share one focus region so tvOS treats everything
                // below the fold as a single page with a single scroll anchor —
                // moving between the cast and similar rows stays put instead of
                // nudging the offset per row.
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    CastShelfSection(people: displayItem.people ?? [])

                    SimilarItemsSection(items: similarItems)
                }
                #if os(tvOS)
                .focusSection()
                .focused($focusedRegion, equals: .shelves)
                #endif
            }
            // Each section (hero, Cast & Crew, More Like This) becomes a snap
            // target so the scroll settles aligned to a section boundary rather
            // than mid-content. Paired with the viewport-tall hero, this gives a
            // clean hero → shelves snap.
            //
            // tvOS is excluded: there scrolling is driven by the focus engine, and
            // `.scrollTargetBehavior` re-aligns the scroll out from under it — which
            // traps focus in the hero. tvOS gets its snap from the focus-region
            // anchors below instead. Snapping here applies on visionOS / iOS only.
            #if !os(tvOS)
            .scrollTargetLayout()
            #endif
            // Bottom-only padding: a top inset would push the viewport-tall,
            // bottom-anchored hero below the fold, guaranteeing the focus engine
            // scrolls (and blurs the backdrop) the moment focus lands on Play.
            .padding(.bottom, SpacingTokens.md)
        }
        .scrollClipDisabled()
        #if !os(tvOS)
        .scrollTargetBehavior(.viewAligned)
        #endif
        #if os(tvOS)
        .scrollPosition($scrollPosition)
        // The tvOS counterpart of `.viewAligned`: when focus crosses the
        // hero/shelves boundary, snap to that region's anchor instead of the
        // focus engine's minimal-reveal offset. The page always reads as either
        // "hero, perfectly framed" (progress 0, crisp backdrop) or "shelves"
        // (progress 1, dimmed wash) — never somewhere in between.
        .onChange(of: focusedRegion) { _, region in
            guard let region else { return }
            withAnimation(theme.animation) {
                scrollPosition.scrollTo(edge: region == .hero ? .top : .bottom)
            }
        }
        #endif
        // Map the live scroll offset to 0...1 so the hero treatment animates with
        // the scroll. `contentOffset.y + contentInsets.top` is 0 at rest and grows
        // as the content scrolls up; no `withAnimation` here — the scroll itself
        // provides the continuity. The threshold dead-bands small focus-engine
        // settles so they never start the fade. Redundant writes are skipped so
        // scrolling past the fold (where the clamp pins progress at 1) stops
        // invalidating.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            let progress = min(max((offset - Self.heroFadeThreshold) / Self.heroFadeDistance, 0), 1)
            if progress != scrollProgress {
                scrollProgress = progress
            }
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

    private var overviewOverlay: OverviewOverlay {
        OverviewOverlay(
            tagline: displayItem.tagline,
            overview: displayItem.overview,
            backdropURL: session.client?.backdropURL(for: displayItem)
        )
    }

    // MARK: - Hero backdrop

    /// Resolves the backdrop URL and mounts `MediaDetailHeroBackdrop`, which owns
    /// the melt/dim/blur treatment driven by `scrollProgress`.
    @ViewBuilder
    private var heroBackground: some View {
        if let client = session.client,
           let url = client.backdropURL(for: displayItem)
        {
            MediaDetailHeroBackdrop(url: url, progress: scrollProgress)
        }
    }

    // MARK: - Data

    /// Crew functions that some servers stuff into a person's `role` while still
    /// tagging `kind` as "Actor". Used to recognize crew (and exclude them from
    /// the billed-cast list) regardless of which field carries the credit.
    private static let crewRoles: Set<String> = [
        "Director", "Writer", "Producer",
        "Executive Producer", "Co-Producer", "Co-Executive Producer"
    ]

    private func loadContent() async {
        guard let client = session.client else { return }

        // Failures degrade gracefully: keep the passed-in stub, skip the shelf.
        detailedItem = (try? await client.getMediaItem(itemId: item.id)) ?? item

        // Derive the credits once per fetch instead of per body evaluation.
        // Directors: handles both standard data (`kind == "Director"`) and servers
        // that report everyone as `kind == "Actor"` with the function in `role`.
        // Top cast: first 3 billed actors, excluding mislabeled crew.
        let people = detailedItem?.people ?? []
        directors = people.filter { $0.kind == "Director" || $0.role == "Director" }
        topCast = Array(
            people
                .filter { $0.kind == "Actor" && !(($0.role).map(Self.crewRoles.contains) ?? false) }
                .prefix(3)
        )

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

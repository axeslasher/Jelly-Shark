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

    /// Series-only state: the season list, every episode in series order (one
    /// continuous shelf spans all seasons), and the episode the hero Play
    /// button resolves to.
    @State private var seasons: [MediaItem] = []
    @State private var episodes: [MediaItem] = []
    @State private var nextUpEpisode: MediaItem?

    /// BoxSet-only state: the collection's contents, in release order.
    @State private var collectionItems: [MediaItem] = []

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
    /// crossing this boundary snaps the scroll to the matching anchor — the
    /// content top for the hero, the shelves' own top for the shelves (see the
    /// `onChange` in `body`). Focus moves *within* a region don't change it, so
    /// nothing re-scrolls.
    private enum FocusRegion: Hashable {
        case hero
        case shelves
    }

    /// Geometry the tvOS shelves snap needs (see `ScrollSnapMetrics`).
    @State private var snapMetrics = ScrollSnapMetrics(containerHeight: 0, topInset: 0)

    @FocusState private var focusedRegion: FocusRegion?

    /// Handle for the two-anchor snap; only written on tvOS.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Pending region snap (see `onChange(of: focusedRegion)`).
    @State private var regionSnapTask: Task<Void, Never>?

    /// The item currently being played, driving the player cover. Set by the
    /// hero Play button (resolved next-up episode / the movie itself) and by
    /// episode cards, which play immediately on click.
    @State private var playbackItem: MediaItem?

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

    /// Collection pages show the span of their contents' release years in
    /// the hero metadata ("1984–2024"); nil (item's own year) until the
    /// contents load, and for every other page type.
    private var collectionYearSpan: String? {
        guard item.type == .boxSet else { return nil }
        let years = collectionItems.compactMap(\.productionYear)
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// What the hero Play button actually plays: series pages resolve to the
    /// next-up episode (falling back to the selected season's first episode),
    /// collection pages to their first unwatched item (falling back to the
    /// first item — a collection itself isn't playable); everything else
    /// plays the page's own item. Nil while a resolved target hasn't loaded
    /// yet — Play stays disabled rather than sending a container to the
    /// player.
    private var playableItem: MediaItem? {
        switch item.type {
        case .series:
            return nextUpEpisode ?? episodes.first
        case .boxSet:
            return collectionItems.first { !($0.userData?.played ?? false) } ?? collectionItems.first
        default:
            return item
        }
    }

    /// Play-button title: series pages name their target episode
    /// ("Resume S2E4"), collection pages their target movie ("Play Jaws 2");
    /// everything else keeps plain Play/Resume.
    private var playButtonTitle: String {
        switch item.type {
        case .series:
            guard let episode = playableItem, episode.type == .episode else { return "Play" }
            let verb = episode.hasProgress ? "Resume" : "Play"
            return episode.episodeCode.map { "\(verb) \($0)" } ?? verb
        case .boxSet:
            // Movie titles get long; a positional label reads better on the
            // button. "Play Next" only while the collection is genuinely in
            // progress — untouched or fully watched both restart at the top.
            let watchedCount = collectionItems.count { $0.userData?.played ?? false }
            let inProgress = watchedCount > 0 && watchedCount < collectionItems.count
            return inProgress ? "Play Next" : "Play First"
        default:
            return displayItem.hasProgress ? "Resume" : "Play"
        }
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
                    yearSpanOverride: collectionYearSpan,
                    playTitle: playButtonTitle,
                    playTarget: playableItem,
                    playbackItem: $playbackItem,
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

                // Everything below the fold shares one focus region so tvOS
                // treats it as a single page with a single scroll anchor —
                // moving between the cast and similar rows stays put instead of
                // nudging the offset per row. The info section isn't focusable;
                // it just rides along at the bottom of the page.
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    // Episodes lead on series pages — they're the reason the
                    // page was opened. Renders nothing for other types.
                    EpisodesSection(
                        seasons: seasons,
                        episodes: episodes,
                        // Same target the Play button resolves to: the shelf
                        // pre-parks there and first focus lands on it.
                        initialEpisodeId: (nextUpEpisode ?? episodes.first)?.id,
                        isRegionFocused: focusedRegion == .shelves,
                        playbackItem: $playbackItem
                    )

                    // Likewise, the contents lead on collection pages.
                    // Renders nothing for other types.
                    CollectionItemsSection(items: collectionItems)

                    CastShelfSection(people: displayItem.people ?? [])

                    SimilarItemsSection(items: similarItems)

                    MediaInfoSection(item: displayItem)
                }
                #if os(tvOS)
                .focusSection()
                .focused($focusedRegion, equals: .shelves)
                #endif
            }
            // Each section (hero, shelves) becomes a snap target so the scroll
            // settles aligned to a section boundary rather than mid-content.
            // Paired with the viewport-tall hero, this gives a clean hero →
            // shelves snap.
            //
            // tvOS is fully excluded from the scroll-target machinery: on
            // hardware (Siri Remote pan gestures — a path the simulator's
            // arrow keys never exercise) the target layout lets the pan drive
            // the scroll view directly, blowing past focusable content with
            // focus left behind. The tvOS focus-region snap below scrolls by
            // geometry instead of by id, so it doesn't need the marker.
            #if os(visionOS)
            .scrollTargetLayout()
            #endif
            // Bottom-only padding: a top inset would push the viewport-tall,
            // bottom-anchored hero below the fold, guaranteeing the focus engine
            // scrolls (and blurs the backdrop) the moment focus lands on Play.
            .padding(.bottom, SpacingTokens.md)
        }
        .scrollClipDisabled()
        #if os(visionOS)
        .scrollTargetBehavior(.viewAligned)
        #endif
        #if os(tvOS)
        .scrollPosition($scrollPosition)
        // The tvOS counterpart of `.viewAligned`: when focus crosses the
        // hero/shelves boundary, snap to that region's anchor instead of the
        // focus engine's minimal-reveal offset. The page always reads as either
        // "hero, perfectly framed" (progress 0, crisp backdrop) or "shelves from
        // the top" (progress 1, dimmed wash) — never somewhere in between. When
        // the shelves outgrow one viewport (info section, tall shelves), the
        // focus engine still nudges further down as focus descends; this anchor
        // only defines where the page *arrives*.
        .onChange(of: focusedRegion) { _, region in
            regionSnapTask?.cancel()
            guard let region else { return }
            regionSnapTask = Task {
                // Let the focus engine finish its own reveal scroll (and any
                // in-region focus steering) first, then assert the page
                // anchor over it — otherwise the engine's settle wins the
                // race and the page parks at an in-between offset.
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                withAnimation(theme.animation) {
                    if region == .hero {
                        scrollPosition.scrollTo(edge: .top)
                    } else {
                        // By geometry, not id: the hero is exactly one
                        // container tall, so the shelves start one container
                        // plus one section gap into the content. (Id-based
                        // scrolls need `scrollTargetLayout`, which is what
                        // hijacks Siri Remote pans on hardware.)
                        scrollPosition.scrollTo(
                            y: snapMetrics.containerHeight + SpacingTokens.sectionSpacing - snapMetrics.topInset
                        )
                    }
                }
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
        // Capture the geometry the tvOS shelves snap needs: the shelves' top
        // sits one viewport-tall hero plus one section gap into the content.
        .onScrollGeometryChange(for: ScrollSnapMetrics.self) { geometry in
            ScrollSnapMetrics(
                containerHeight: geometry.containerSize.height,
                topInset: geometry.contentInsets.top
            )
        } action: { _, metrics in
            snapMetrics = metrics
        }
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
        .fullScreenCover(item: $playbackItem, onDismiss: refreshAfterPlayback) { target in
            if let client = session.client {
                PlaybackContainerView(client: client, item: target)
            }
        }
        .fullScreenCover(isPresented: $isPresentingOverview) {
            overviewOverlay
        }
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
            MediaDetailHeroBackdrop(
                url: url,
                blurHash: displayItem.backdropBlurHash,
                progress: scrollProgress
            )
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

    /// Playback changes server-side user data this view displays — resume
    /// position (hero Play/Resume button), watched flags on episode cards,
    /// and next-up. `loadContent` only re-runs when the item id changes, so
    /// re-fetch in place when the player dismisses; unlike `loadContent`,
    /// nothing is blanked first, so already-rendered shelves don't flash.
    private func refreshAfterPlayback() {
        Task {
            guard let client = session.client else { return }

            if let refreshed = try? await client.getMediaItem(itemId: item.id) {
                detailedItem = refreshed
            }

            if item.type == .series {
                async let episodesFetch = client.getEpisodes(seriesId: item.id, seasonId: nil)
                async let nextUpFetch = client.getNextUpEpisode(seriesId: item.id)
                if let refreshedEpisodes = await (try? episodesFetch) {
                    episodes = refreshedEpisodes
                }
                nextUpEpisode = await (try? nextUpFetch) ?? nil
            }

            // Watched flags on the collection cards (and the Play target's
            // first-unwatched resolution) change with playback too.
            if item.type == .boxSet {
                if let refreshedItems = try? await client.getCollectionItems(collectionId: item.id) {
                    collectionItems = refreshedItems
                }
            }
        }
    }

    private func loadContent() async {
        guard let client = session.client else { return }

        // Reset per-type state so a reused view (item.id change) doesn't show
        // the previous item's seasons or collection contents while the new
        // ones load.
        seasons = []
        episodes = []
        nextUpEpisode = nil
        collectionItems = []

        // Failures degrade gracefully: keep the passed-in stub, skip the shelf.
        detailedItem = (try? await client.getMediaItem(itemId: item.id)) ?? item

        if item.type == .series {
            async let seasonsFetch = client.getSeasons(seriesId: item.id)
            async let episodesFetch = client.getEpisodes(seriesId: item.id, seasonId: nil)
            async let nextUpFetch = client.getNextUpEpisode(seriesId: item.id)
            seasons = (await (try? seasonsFetch)) ?? []
            episodes = (await (try? episodesFetch)) ?? []
            nextUpEpisode = await (try? nextUpFetch) ?? nil
        }

        if item.type == .boxSet {
            collectionItems = (try? await client.getCollectionItems(collectionId: item.id)) ?? []
        }

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

/// Container geometry captured for the tvOS shelves snap: the shelves' top
/// offset is derived from these rather than an id lookup, so the snap works
/// without `scrollTargetLayout`.
private struct ScrollSnapMetrics: Equatable {
    var containerHeight: CGFloat
    var topInset: CGFloat
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
                criticRating: 93,
                officialRating: "PG-13",
                genres: ["Crime", "Drama", "Thriller"],
                studios: ["A24"],
                premiereDate: Date(timeIntervalSince1970: 1_700_000_000),
                technicalInfo: MediaTechnicalInfo(
                    resolution: "4K",
                    videoRange: "Dolby Vision",
                    audioFormat: "Dolby Atmos",
                    originalAudioLanguage: "English",
                    audioLanguages: ["English", "French"],
                    subtitleLanguages: ["English", "French", "Spanish"],
                    hasSDHSubtitles: true,
                    fileName: "Example.Movie.2024.2160p.DV.mkv",
                    fileSizeBytes: 42_000_000_000,
                    container: "MKV",
                    videoCodec: "HEVC",
                    bitrate: 24_500_000,
                    frameRate: 23.976
                )
            )
        )
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

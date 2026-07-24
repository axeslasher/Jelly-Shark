import DesignSystem
import JellyfinKit
import SwiftUI

/// Title + SF Symbol for the hero Play button on plain (movie / episode)
/// pages — the series and collection labels are computed separately.
///
/// `playedOverride` is the optimistic watched toggle. Marking watched *or*
/// unwatched clears the server-side resume position, so a pending override
/// supersedes the item's stored progress: watched reads "Replay" (with the
/// circular-arrow icon the played shelf badge uses), unwatched drops straight
/// to "Play" (never a stale "Resume"). Absent an override, a fully-watched
/// item still reads "Replay", an in-progress one "Resume".
enum HeroPlayLabel {
    static func label(
        playedOverride: Bool?,
        played: Bool,
        hasProgress: Bool,
    ) -> (title: String, systemImage: String) {
        let replay = (title: "Replay", systemImage: "arrow.counterclockwise")
        let play = (title: "Play", systemImage: "play.fill")
        if let playedOverride {
            return playedOverride ? replay : play
        }
        if played {
            return replay
        }
        return hasProgress ? (title: "Resume", systemImage: "play.fill") : play
    }
}

/// Detail view for a media item.
///
/// Mirrors `HomeView`'s hero treatment: a full-bleed backdrop that melts into the
/// background behind a left-aligned title, metadata row, and Play button, followed
/// by the overview and Cast & Crew / More Like This shelves.
///
/// Each section is its own `View` struct (not a computed property) so it forms an
/// invalidation boundary, and the per-tick scroll values live on
/// `MediaDetailScrollState` so a scroll tick re-evaluates only the two leaf
/// views that read them (the backdrop bridge and the hero drift wrapper) —
/// never this body or the episode/cast/similar shelves below it.
public struct MediaDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(\.pushMediaDetail) private var pushMediaDetail

    /// Owns every server-side fetch and its status; this view keeps only
    /// presentation state (scroll, focus, playback covers).
    @State private var viewModel = MediaDetailViewModel()

    /// The live scroll values, on an @Observable object instead of @State:
    /// per-tick writes then invalidate only the views whose bodies read the
    /// written property, and this body reads none of them. As @State, every
    /// tick re-ran this body and re-diffed the closure-carrying episode/cast
    /// shelves — the view-graph churn behind season-heavy pages pinning the
    /// main thread (#105 Track B).
    @State private var scroll = MediaDetailScrollState()

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

    /// Dead-band (points) for the tvOS region snap: focus settles within this of
    /// an anchor don't re-fire the snap, so it stops racing the focus engine's
    /// own reveal scroll. Mirrors `HomeHeroMotion.snapSlack`.
    private static let snapSlack: CGFloat = 24

    /// How close (points) the scroll must come to `shelvesAnchor` before a
    /// series' season-anchor row reveals. Keyed off the raw offset's *arrival at
    /// the shelves*, not `scrollProgress` — progress saturates ~350pt in (a
    /// distance tuned for the hero melt, far short of the shelves), so keying the
    /// reveal to it resolves the fade mid-scroll. Arrival-keyed, the row fades in
    /// *after* the scroll settles, like Home's Continue Watching header. Larger =
    /// more lead before the anchor (earlier reveal).
    private static let seasonAnchorRevealSlack: CGFloat = 120

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
        viewModel.detailedItem ?? item
    }

    /// Collection pages show the span of their contents' release years in
    /// the hero metadata ("1984–2024"); nil (item's own year) until the
    /// contents load, and for every other page type.
    private var collectionYearSpan: String? {
        guard item.type == .boxSet else { return nil }
        let years = viewModel.collectionItems.compactMap(\.productionYear)
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    /// What replaces the item's own year in the hero metadata: collections
    /// pass their contents' span, episodes their air date (which matters more
    /// than the season's production year). Nil falls back to the item's year.
    private var heroYearOverride: String? {
        switch item.type {
        case .boxSet:
            collectionYearSpan
        case .episode:
            displayItem.premiereDate?.formatted(date: .abbreviated, time: .omitted)
        default:
            nil
        }
    }

    /// Where the shelves' top parks on the tvOS region snap: the hero is exactly
    /// one container tall, so the shelves start one container plus one section gap
    /// into the content. Kept as MediaDetail's own expression (small inset,
    /// full-viewport hero) — not Home's fractional formula.
    private var shelvesAnchor: CGFloat {
        snapMetrics.containerHeight + SpacingTokens.sectionSpacing - snapMetrics.topInset
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
            viewModel.nextUpEpisode ?? viewModel.episodes.first
        case .boxSet:
            viewModel.collectionItems.first { !($0.userData?.played ?? false) } ?? viewModel.collectionItems.first
        default:
            item
        }
    }

    /// Play-button title + icon: series pages name their target episode
    /// ("Resume S2E4"), collection pages their target movie ("Play Jaws 2") —
    /// both keep the play glyph; everything else is Play / Resume / Replay
    /// (see `HeroPlayLabel`), where Replay swaps in the circular-arrow icon.
    private var playButtonLabel: (title: String, systemImage: String) {
        switch item.type {
        case .series:
            guard let episode = playableItem, episode.type == .episode else { return ("Play", "play.fill") }
            let verb = episode.hasProgress ? "Resume" : "Play"
            return (episode.episodeCode.map { "\(verb) \($0)" } ?? verb, "play.fill")
        case .boxSet:
            // Movie titles get long; a positional label reads better on the
            // button. "Play Next" only while the collection is genuinely in
            // progress — untouched or fully watched both restart at the top.
            let watchedCount = viewModel.collectionItems.count { $0.userData?.played ?? false }
            let inProgress = watchedCount > 0 && watchedCount < viewModel.collectionItems.count
            return (inProgress ? "Play Next" : "Play First", "play.fill")
        default:
            return HeroPlayLabel.label(
                playedOverride: viewModel.heroPlayedOverride,
                played: displayItem.userData?.played ?? false,
                hasProgress: displayItem.hasProgress,
            )
        }
    }

    public var body: some View {
        ScrollView {
            // A plain VStack (not LazyVStack): there are only ever three sections,
            // and on tvOS the focus engine can't move focus into — and therefore
            // can't scroll to — a section that a lazy stack hasn't built yet. The
            // per-shelf horizontal scrolls remain lazy on their own.
            VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                // The wrapper drifts the hero lockup as it scrolls, in lockstep
                // with the backdrop's melt/dim/blur. Offset only — no opacity
                // fade: fading the hero to opacity 0 makes its controls
                // unfocusable on tvOS (scrolling is focus movement there),
                // which strands the scroll. A wrapper so the per-tick
                // `progress` read stays out of this body, and the hero's
                // inputs stay unchanged during scroll so its body is skipped.
                HeroExitDrift(scroll: scroll, drift: Self.heroScrollDrift) {
                    MediaDetailHeroSection(
                        viewModel: viewModel,
                        item: displayItem,
                        directors: viewModel.directors,
                        topCast: viewModel.topCast,
                        yearSpanOverride: heroYearOverride,
                        playTitle: playButtonLabel.title,
                        playIcon: playButtonLabel.systemImage,
                        playTarget: playableItem,
                        playbackItem: $playbackItem,
                        isPresentingOverview: $isPresentingOverview,
                    )
                }
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
                    // While the core load is in flight, ghost the sections it
                    // will fill (per page type) instead of letting them pop
                    // in. Ghosts aren't focusable, so tvOS focus stays on the
                    // stub hero until real shelves land — same as before,
                    // when this region rendered nothing.
                    if viewModel.status == .loading {
                        sectionSkeletons
                    } else {
                        // The core load failed: the stub hero above still renders
                        // (title, poster, often Play), so degrade in place — the
                        // notice sits where the missing sections would, and its
                        // Retry button keeps this focus region reachable.
                        if viewModel.status.isFailed {
                            FailedShelfNotice(
                                message: "Couldn't load details — check your connection",
                                retry: { Task { await viewModel.retry() } },
                            )
                        }

                        loadedSections
                    }

                    // More Like This resolves after the core status settles
                    // (it's enrichment), so it swaps its own ghost — keyed to
                    // its own fetch — for the shelf, independent of the above.
                    // Episode pages skip it outright (the season shelf is
                    // their kin section; "more like this episode" is dubious)
                    // — gated here too so its ghost never flashes.
                    if item.type != .episode {
                        if viewModel.isSimilarLoading {
                            SkeletonShelf(cardWidth: 200, shape: .artwork(aspectRatio: 2.0 / 3.0))
                                .skeletonPulse()
                        } else {
                            SimilarItemsSection(items: viewModel.similarItems)
                        }
                    }

                    MediaInfoSection(item: displayItem)
                }
                #if os(tvOS)
                .focusSection()
                .focused($focusedRegion, equals: .shelves)
                #endif
            }
            // No scroll-target snapping: the content scrolls freely, matching
            // HomeView. `.viewAligned` here (with only a hero + shelves target)
            // is what made the page fight the user — flinging blew past the
            // cast/similar rows and every settle snapped to one of two anchors.
            // visionOS now scrolls continuously; tvOS keeps its own focus-region
            // snap below (by geometry, never `scrollTargetLayout`, which hijacks
            // Siri Remote pans on hardware).
            //
            // Bottom-only padding: a top inset would push the viewport-tall,
            // bottom-anchored hero below the fold, guaranteeing the focus engine
            // scrolls (and blurs the backdrop) the moment focus lands on Play.
            .padding(.bottom, SpacingTokens.md)
        }
        .scrollClipDisabled()
        #if os(tvOS)
            .scrollPosition($scrollPosition)
            // When focus crosses the hero/shelves boundary, park the scroll at that
            // region's anchor (by geometry, not id — id targets need
            // `scrollTargetLayout`, which hijacks Siri Remote pans). The `snapSlack`
            // dead-band and directional guards (mirroring HomeView) keep this from
            // re-firing and racing the focus engine: the hero snap only pulls up when
            // meaningfully scrolled down, and the shelves snap only ever pulls *down*
            // to the anchor — never yanks the page back up out from under a focused
            // row deeper in the shelves (the scroll-jack).
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
                    switch region {
                    case .hero:
                        guard scroll.offset > Self.snapSlack else { return }
                        withAnimation(theme.animation) {
                            scrollPosition.scrollTo(edge: .top)
                        }
                    case .shelves:
                        guard scroll.offset < shelvesAnchor - Self.snapSlack else { return }
                        withAnimation(theme.animation) {
                            scrollPosition.scrollTo(y: shelvesAnchor)
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
                    topInset: geometry.contentInsets.top,
                )
            } action: { _, metrics in
                snapMetrics = metrics
                updateSeasonAnchorReveal()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                // Raw offset drives the tvOS region-snap guards (which compare
                // points); keep it before the progress clamp saturates it.
                if offset != scroll.offset {
                    scroll.offset = offset
                }
                let progress = min(max((offset - Self.heroFadeThreshold) / Self.heroFadeDistance, 0), 1)
                if progress != scroll.progress {
                    scroll.progress = progress
                }
                updateSeasonAnchorReveal()
            }
            .background(alignment: .top) { heroBackground }
            .background(theme.background)
            .task(id: item.id) {
                viewModel.attach(client: session.client, item: item)
                await viewModel.load()
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

    /// The below-the-fold sections once the core load has settled.
    @ViewBuilder
    private var loadedSections: some View {
        // Episodes lead on series pages — they're the reason the
        // page was opened. Renders nothing for other types.
        EpisodesSection(
            seasons: viewModel.seasons,
            episodes: viewModel.episodes,
            // Same target the Play button resolves to: the shelf
            // pre-parks there and first focus lands on it.
            initialEpisodeId: (viewModel.nextUpEpisode ?? viewModel.episodes.first)?.id,
            isRegionFocused: focusedRegion == .shelves,
            // Hidden while the hero owns the screen (so tvOS focus
            // flows past it to the parked episode); fades in only once
            // the scroll has essentially arrived at the shelves anchor
            // — a beat *after* the settle, not mid-melt. A stored Bool
            // (see `updateSeasonAnchorReveal`), so this body observes
            // its flips, never the raw offset ramp.
            showsSeasonAnchors: scroll.revealsSeasonAnchors,
            menu: { episode in
                ShelfMenuHandlers(
                    viewDetails: { pushMediaDetail?(episode) },
                    setPlayed: { played in
                        Task { await viewModel.setPlayed(played, for: episode) }
                    },
                    setFavorite: { favorite in
                        Task { await viewModel.setFavorite(favorite, for: episode) }
                    },
                )
            },
            playbackItem: $playbackItem,
        )

        // Likewise, the contents lead on collection pages.
        // Renders nothing for other types.
        CollectionItemsSection(items: viewModel.collectionItems)

        // And the rest of the season leads on episode pages, parked on
        // the page's own episode. Renders nothing for other types.
        SeasonEpisodesSection(
            title: displayItem.seasonName ?? "Episodes",
            episodes: viewModel.seasonEpisodes,
            currentEpisodeId: item.id,
            isRegionFocused: focusedRegion == .shelves,
            menu: { episode in
                ShelfMenuHandlers(
                    viewDetails: { pushMediaDetail?(episode) },
                    setPlayed: { played in
                        Task { await viewModel.setPlayed(played, for: episode) }
                    },
                    setFavorite: { favorite in
                        Task { await viewModel.setFavorite(favorite, for: episode) }
                    },
                )
            },
            playbackItem: $playbackItem,
        )

        // On pages with no leading section (movies) the focus engine
        // can skip the cast row and grab More Like This; steer first
        // focus onto cast. Gated off when a leading section exists
        // (those steer their own first focus), so two steers never
        // both fire.
        CastShelfSection(
            people: displayItem.people ?? [],
            isRegionFocused: focusedRegion == .shelves,
            steersFirstFocus: viewModel.seasons.isEmpty
                && viewModel.collectionItems.isEmpty
                && viewModel.seasonEpisodes.isEmpty,
        )
    }

    /// Ghosts of the sections the core load will fill, mirroring what this
    /// page type renders: episode stills on series, the contents' posters on
    /// collections, then the cast row's headshots. More Like This has its own
    /// ghost, keyed to its own fetch.
    private var sectionSkeletons: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            // Series and episode pages both lead with a 16:9 episode shelf.
            if item.type == .series || item.type == .episode {
                SkeletonShelf(
                    cardWidth: 440,
                    shape: .artwork(aspectRatio: 16.0 / 9.0),
                    cardCount: 4,
                )
            }

            if item.type == .boxSet {
                SkeletonShelf(cardWidth: 316, shape: .artwork(aspectRatio: 2.0 / 3.0))
            }

            SkeletonShelf(cardWidth: 200, shape: .circle)
        }
        .skeletonPulse()
    }

    private var overviewOverlay: OverviewOverlay {
        OverviewOverlay(
            // Episodes headline the overlay with their own title under the
            // season/episode eyebrow, matching the hero's overview lockup.
            eyebrow: displayItem.seasonEpisodeText,
            tagline: item.type == .episode ? displayItem.name : displayItem.tagline,
            overview: displayItem.overview,
            backdropURL: viewModel.heroBackdropURL(for: displayItem),
        )
    }

    // MARK: - Hero backdrop

    /// Resolves the backdrop URL and mounts `MediaDetailHeroBackdrop`, which owns
    /// the melt/dim/blur treatment driven by `scrollProgress`. The view model
    /// picks the image (an episode hero may ride its own primary still
    /// instead of a backdrop — see `heroBackdropURL(for:)`).
    @ViewBuilder
    private var heroBackground: some View {
        if session.client != nil,
           let url = viewModel.heroBackdropURL(for: displayItem)
        {
            // The bridge owns the per-tick `progress` read, so ticks re-run
            // its body, not this one.
            HeroBackdropBridge(
                scroll: scroll,
                url: url,
                blurHash: viewModel.heroBackdropBlurHash(for: displayItem),
            )
        }
    }

    /// Recomputed on scroll ticks and container-geometry changes; stored as a
    /// Bool so the episodes section observes only its flips. The
    /// containerHeight gate suppresses a false reveal before the geometry is
    /// measured (which would also skip the steer).
    private func updateSeasonAnchorReveal() {
        let reveals = snapMetrics.containerHeight > 0
            && scroll.offset >= shelvesAnchor - Self.seasonAnchorRevealSlack
        if reveals != scroll.revealsSeasonAnchors {
            scroll.revealsSeasonAnchors = reveals
        }
    }

    // MARK: - Data

    /// Watch state moves during playback; hand the in-place refresh to the
    /// view model once the player dismisses.
    private func refreshAfterPlayback() {
        Task {
            await viewModel.refreshAfterPlayback()
        }
    }
}

/// The detail page's per-scroll-tick values. @Observable, so a write
/// invalidates only the views whose bodies read the written property — never
/// `MediaDetailView.body`, which reads only the stored
/// `revealsSeasonAnchors` flips.
@Observable @MainActor
private final class MediaDetailScrollState {
    /// Raw scroll offset in points (`contentOffset.y + contentInsets.top`, 0
    /// at rest). The tvOS region snap's guards compare against this —
    /// `progress` saturates at 1 well before the shelves anchor, so it can't
    /// drive them.
    var offset: CGFloat = 0

    /// Continuous scroll progress for the hero treatment: 0 at the top,
    /// ramping to 1 once the backdrop has scrolled `heroFadeDistance` points.
    /// Drives the melt/dim/blur so the transition tracks the scroll instead
    /// of snapping after the hero leaves the screen.
    var progress: CGFloat = 0

    /// The scroll has essentially arrived at the shelves anchor — see
    /// `updateSeasonAnchorReveal`.
    var revealsSeasonAnchors = false
}

/// Applies the hero's scroll-linked exit drift while keeping the per-tick
/// `progress` read out of the parent's body: the wrapped content is built by
/// the parent, so when a tick re-runs this body the content value is
/// unchanged and its body is skipped — only the offset moves.
private struct HeroExitDrift<Content: View>: View {
    let scroll: MediaDetailScrollState
    let drift: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(y: scroll.progress * drift)
    }
}

/// Bridges the live scroll values into `MediaDetailHeroBackdrop`'s plain
/// inputs, so the per-tick reads land in this leaf body instead of
/// `MediaDetailView`'s.
private struct HeroBackdropBridge: View {
    let scroll: MediaDetailScrollState
    let url: URL
    let blurHash: String?

    var body: some View {
        MediaDetailHeroBackdrop(
            url: url,
            blurHash: blurHash,
            progress: scroll.progress,
        )
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
                    frameRate: 23.976,
                ),
            ),
        )
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

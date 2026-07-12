import DesignSystem
import JellyfinKit
import SwiftUI

/// Home: a paged hero marquee over the curated latest additions, with
/// Continue Watching, Next Up, per-library Recently Added, and genre shelves
/// below the fold.
///
/// This view is a thin composer — loading lives in `HomeViewModel` (and
/// `GenreShelvesViewModel` for the genre rows), the hero visuals in
/// `HomeHeroSection`/`HomeHeroBackdrop`. Sections are `View` structs so the
/// per-tick scroll offset only re-evaluates this body and the backdrop.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel = HomeViewModel()
    @State private var genreShelves = GenreShelvesViewModel()

    /// The item being played, driving the player cover — set by the hero Play
    /// button and the Continue Watching / Next Up cards (which play
    /// immediately on click).
    @State private var playbackItem: MediaItem?

    /// Live scroll offset; the hero backdrop rides it so hero and backdrop
    /// slide up as one unit.
    @State private var scrollOffset: CGFloat = 0

    /// Hero exit progress (0...1) mapped from the scroll offset — drives the
    /// lockup's extra drift and the backdrop fade, and reverses on the way
    /// back up. No `withAnimation`: the scroll itself provides continuity
    /// (and the region snap's animated scroll animates it for free).
    @State private var scrollProgress: CGFloat = 0

    /// Whether the hero has scrolled far enough away to pause the carousel.
    @State private var isHeroOffscreen = false

    /// Which page region owns focus on tvOS (see MediaDetailView's region
    /// snap for the pattern). Crossing the boundary snaps the scroll to that
    /// region's anchor — the hero "slides up" when the shelves take focus.
    private enum FocusRegion: Hashable {
        case hero
        case shelves
    }

    @FocusState private var focusedRegion: FocusRegion?
    @State private var snapMetrics = ScrollSnapMetrics(containerHeight: 0, topInset: 0)
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var regionSnapTask: Task<Void, Never>?

    /// Where the shelves' top parks: one fractional hero plus the hero→shelf
    /// gap into the content. `scrollTo(y:)` works in the same inset-adjusted
    /// space as our tracked offset, so no `topInset` correction — subtracting
    /// it (as MediaDetail's small-inset pages do) double-counts Home's large
    /// tab-bar inset and parks the row a whole inset too low.
    private var shelvesAnchor: CGFloat {
        snapMetrics.containerHeight * HomeHeroMotion.heroHeightFraction
            + HomeHeroMotion.heroToShelvesGap
    }

    /// No NavigationStack here: RootView owns each tab's stack (with a path
    /// binding) so it can pop to root before a tab switch — see RootView's
    /// `tabSelection` for the tvOS bug this works around.
    var body: some View {
        Group {
            if session.isConnected, viewModel.isInitialLoading {
                HomeSkeleton()
            } else if !session.isConnected || viewModel.isEmptyServer {
                HomeEmptyState(
                    isConnected: session.isConnected,
                    userName: connection.connectedUser?.name,
                )
            } else {
                contentScroll
            }
        }
        // Fill the window even in the non-scrolling states (skeleton, empty),
        // so the theme background covers the screen edge to edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(theme.animation, value: viewModel.isInitialLoading)
        .background(theme.background)
        .task(id: session.isConnected) {
            viewModel.attach(client: session.client, libraries: connection.libraries)
            await viewModel.load()
            genreShelves.attach(client: session.client, libraries: connection.libraries)
            await genreShelves.load()
        }
        .onChange(of: reduceMotion, initial: true) { _, isReduced in
            viewModel.setPaused(isReduced, reason: .reduceMotion)
        }
        .onDisappear {
            viewModel.stopAutoAdvance()
        }
        .onAppear {
            viewModel.startAutoAdvance()
        }
        .fullScreenCover(item: $playbackItem, onDismiss: refreshAfterPlayback) { target in
            if let client = session.client {
                PlaybackContainerView(client: client, item: target)
            }
        }
    }

    private var contentScroll: some View {
        ScrollView {
            // A plain VStack (not LazyVStack): on tvOS the focus engine can't
            // move focus into a section a lazy stack hasn't built yet. The
            // per-shelf horizontal scrolls stay lazy on their own. Spacing
            // here is only the hero→shelves gap (tighter than the section
            // spacing the shelves keep between themselves).
            VStack(alignment: .leading, spacing: HomeHeroMotion.heroToShelvesGap) {
                HomeHeroSection(
                    items: viewModel.heroItems,
                    index: viewModel.heroIndex,
                    playTarget: viewModel.heroPlayTarget,
                    onPlay: { playbackItem = $0 },
                    onNext: {
                        viewModel.advanceHero()
                        viewModel.noteUserInteraction()
                    },
                )
                // Drift the lockup up faster than the page as it exits, in
                // lockstep with the backdrop fade — and back on the way up.
                // Offset only, never opacity (see HomeHeroMotion.exitDrift).
                // Applied here so the hero's inputs stay unchanged during
                // scroll and its body is skipped.
                .offset(y: scrollProgress * HomeHeroMotion.exitDrift)
                #if os(tvOS)
                    .focusSection()
                    .focused($focusedRegion, equals: .hero)
                #endif

                // Everything below the fold shares one focus region so tvOS
                // treats it as a single page with a single scroll anchor.
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    HomeShelvesSection(
                        resumeItems: viewModel.resumeItems,
                        nextUpItems: viewModel.nextUpItems,
                        latestShelves: viewModel.latestShelves,
                        resumeStatus: viewModel.resumeStatus,
                        nextUpStatus: viewModel.nextUpStatus,
                        latestStatus: viewModel.latestStatus,
                        // Headerless while the hero owns the screen; the
                        // title fades/slides in as the hero exits (always
                        // shown when there's no hero to defer to).
                        showsResumeHeader: viewModel.currentHeroItem == nil
                            || scrollProgress >= HomeHeroMotion.shelfHeaderReveal,
                        onPlay: { playbackItem = $0 },
                    )

                    GenreShelvesView(shelves: genreShelves.shelves)
                }
                #if os(tvOS)
                .focusSection()
                .focused($focusedRegion, equals: .shelves)
                #endif
            }
            .padding(.bottom, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        #if os(tvOS)
            .scrollPosition($scrollPosition)
            // Region snap: when focus crosses the hero/shelves boundary, park the
            // scroll at that region's anchor (by geometry, not id — id targets
            // need `scrollTargetLayout`, which hijacks Siri Remote pans). This is
            // the hero's "slide up": shelves take focus, the page animates to the
            // shelves anchor, and the backdrop rides along via `scrollOffset`.
            .onChange(of: focusedRegion) { _, region in
                viewModel.setPaused(region == .hero, reason: .focused)
                regionSnapTask?.cancel()
                guard let region else { return }
                regionSnapTask = Task {
                    // Let the focus engine finish its own reveal scroll first,
                    // then assert the page anchor over it.
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    switch region {
                    case .hero:
                        guard scrollOffset > HomeHeroMotion.snapSlack else { return }
                        withAnimation(theme.animation) {
                            scrollPosition.scrollTo(edge: .top)
                        }
                    case .shelves:
                        // Unlike Media Detail's one-container hero, Home's
                        // shelves run several screens deep — a fast scroll
                        // lands focus well past the anchor before this fires,
                        // and parking back up would yank the page out from
                        // under the focused row (the focus engine then fights
                        // to re-reveal it: the scroll-jack). Only ever pull
                        // the page *down* to the anchor, never back up.
                        guard scrollOffset < shelvesAnchor - HomeHeroMotion.snapSlack else { return }
                        withAnimation(theme.animation) {
                            scrollPosition.scrollTo(y: shelvesAnchor)
                        }
                    }
                }
            }
        #endif
            .onScrollGeometryChange(for: ScrollSnapMetrics.self) { geometry in
                ScrollSnapMetrics(
                    containerHeight: geometry.containerSize.height,
                    topInset: geometry.contentInsets.top,
                )
            } action: { _, metrics in
                snapMetrics = metrics
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if offset != scrollOffset {
                    scrollOffset = offset
                }
                // Map the offset to exit progress (dead-banding the focus
                // engine's settle); skip redundant writes so scrolling past
                // the fold stops invalidating.
                let progress = min(
                    max((offset - HomeHeroMotion.exitThreshold) / HomeHeroMotion.exitDistance, 0),
                    1,
                )
                if progress != scrollProgress {
                    scrollProgress = progress
                }
                // Pause the carousel once the hero has fully exited; only
                // report boundary crossings so scrolling doesn't spam the
                // view model.
                let offscreen = progress >= 1
                if offscreen != isHeroOffscreen {
                    isHeroOffscreen = offscreen
                    viewModel.setPaused(offscreen, reason: .offscreen)
                }
            }
            .background(alignment: .top) { heroBackground }
            .background(theme.background)
    }

    /// Full-bleed paged backdrop behind the hero. Lives in the scroll view's
    /// background (in-flow views can't escape the safe area) but tracks the
    /// content via `scrollOffset`, so it behaves as part of the hero.
    @ViewBuilder
    private var heroBackground: some View {
        if let client = session.client, let item = viewModel.currentHeroItem {
            HomeHeroBackdrop(
                url: client.backdropURL(for: item),
                blurHash: item.backdropBlurHash,
                itemId: item.id,
                scrollOffset: scrollOffset,
                progress: scrollProgress,
            )
        }
    }

    /// Watched state and progress move during playback; refresh the sections
    /// that show them once the player dismisses.
    private func refreshAfterPlayback() {
        Task {
            await viewModel.refreshUserState()
        }
    }
}

/// Container geometry for the tvOS region snap (same shape as
/// MediaDetailView's — private there, so each page keeps its own copy).
private struct ScrollSnapMetrics: Equatable {
    var containerHeight: CGFloat
    var topInset: CGFloat
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .withThemeEnvironment()
    .environment(AppSession())
    .environment(ServerConnectionViewModel())
}

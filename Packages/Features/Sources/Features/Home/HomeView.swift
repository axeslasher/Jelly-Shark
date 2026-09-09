import DesignSystem
import JellyfinKit
import SwiftUI

/// Home: a paged hero marquee over the curated latest additions, with
/// Continue Watching, Next Up, per-library Recently Added, and genre shelves
/// below the fold.
///
/// This view is a thin composer — loading lives in `HomeViewModel` (and
/// `GenreShelvesViewModel` for the genre rows), the hero visuals in
/// `HomeHeroSection`/`HomeHeroBackdrop`. The per-tick scroll values live on
/// `HomeScrollState`, so a scroll tick re-evaluates only the two leaf views
/// that read them (the backdrop bridge and the hero drift wrapper) — never
/// this body or the shelf subtree.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var connection
    @Environment(HomePreferences.self) private var homePreferences
    @Environment(PlaybackPreferences.self) private var playbackPreferences
    @Environment(ContentRefreshCoordinator.self) private var refreshCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pushMediaDetail) private var pushMediaDetail

    /// Owned by `RootView` so they survive tvOS tearing this tab's view down
    /// on switch — a returning tab repaints from memory in its first layout
    /// pass instead of refetching (#236 § 3).
    let viewModel: HomeViewModel
    let genreShelves: GenreShelvesViewModel
    let ui: HomeUIState
    let isEligible: Bool

    /// The item being played, driving the player cover — set by the hero Play
    /// button and the Continue Watching / Next Up cards (which play
    /// immediately on click).
    @State private var playbackItem: PlaybackRequest?

    /// The live scroll values, on an @Observable object instead of @State:
    /// per-tick writes then invalidate only the views whose bodies read the
    /// written property, and this body reads none of them. As @State, every
    /// tick re-ran this body, whose closure-carrying sections defeat
    /// SwiftUI's input-equality skip — re-running every shelf item body 60x/s
    /// (the worst hitch stretch in the #105 profiling).
    @State private var scroll = HomeScrollState()

    /// Which page region owns focus on tvOS (see MediaDetailView's region
    /// snap for the pattern). Crossing the boundary snaps the scroll to that
    /// region's anchor — the hero "slides up" when the shelves take focus.
    private enum FocusRegion: Hashable {
        case hero
        case shelves
    }

    @FocusState private var focusedRegion: FocusRegion?

    /// Which shelf card owns focus. Restored on a tab return and re-aimed
    /// when a refresh removes the card out from under the viewer (#236 § 11).
    @FocusState private var focusedCard: ShelfFocusID?

    /// The empty state's Settings button — the page's only focusable when
    /// Home has nothing to show.
    @FocusState private var isEmptyStateActionFocused: Bool

    @State private var snapMetrics = ScrollSnapMetrics(containerHeight: 0, topInset: 0)
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var regionSnapTask: Task<Void, Never>?

    /// `RootView`'s pop-settle plus margin, derived rather than restated: if
    /// the settle moves, this must move with it.
    private static var settleGuard: Duration {
        #if os(tvOS)
            RootView.popSettle + .milliseconds(50)
        #else
            .zero
        #endif
    }

    /// Changes whenever a drain is owed: on arrival (eligibility flips) and
    /// on any post while Home is already on screen. `.task(id:)` re-runs only
    /// when its id changes, so keying on arrival alone would miss every
    /// library change and every menu toggle made from Home itself (§ 5.1).
    private struct DrainKey: Equatable {
        let eligible: Bool
        let settled: Bool
        let revision: Int
    }

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
            // The skeleton owns every "still finding out" state — session
            // restore in flight AND section loads in flight — so launch never
            // flashes the disconnected or empty placeholders on its way to
            // content. The placeholders are verdicts, not defaults: Welcome
            // requires the restore to have settled with no connection, and
            // Nothing Here requires every section to have come back empty.
            if session.isConnected {
                if viewModel.isInitialLoading {
                    HomeSkeleton()
                } else if viewModel.isEmptyServer {
                    HomeEmptyState(
                        isConnected: true,
                        userName: connection.connectedUser?.name,
                        actionFocus: $isEmptyStateActionFocused,
                    )
                } else {
                    contentScroll
                }
            } else if connection.hasAttemptedRestore, connection.state == .disconnected {
                HomeEmptyState(isConnected: false, userName: nil, actionFocus: $isEmptyStateActionFocused)
            } else {
                HomeSkeleton()
            }
        }
        // Fill the window even in the non-scrolling states (skeleton, empty),
        // so the theme background covers the screen edge to edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(theme.animation, value: viewModel.isInitialLoading)
        .background(theme.background)
        .task(id: session.isConnected) {
            viewModel.attach(
                client: session.client,
                libraries: connection.libraries,
                cache: session.scopedCache,
                userState: session.userState,
            )
            // Read before the load: reasons raised before it are covered by
            // it, anything posted while it ran is not (§ 8).
            let revisionAtStart = refreshCoordinator.revision
            let didLoad = await viewModel.load()
            genreShelves.attach(client: session.client, libraries: connection.libraries)
            await genreShelves.load()

            // Flipping this is what releases the drain task below — so only a
            // pass that had a client may flip it. This task runs once with
            // `isConnected == false` on every cold launch; that pass takes
            // `load()`'s no-client branch and settles nothing, and opening the
            // gate for it let the drain supersede the real load that follows
            // (#236 § 8.1).
            refreshCoordinator.isInitialLoadSettled = session.client != nil
            // Seed the floor only if a load actually ran: tvOS re-runs this
            // task on every tab return, and stamping the timestamp for a
            // guarded-out call would disable the external-client fallback
            // forever.
            guard didLoad else { return }
            refreshCoordinator.completeInitialLoad(
                revisionAtStart: revisionAtStart,
                succeeded: viewModel.lastLoadOutcome == .succeeded,
                now: .now,
            )
        }
        .task(id: DrainKey(
            eligible: isEligible,
            settled: refreshCoordinator.isInitialLoadSettled,
            revision: refreshCoordinator.revision,
        )) {
            // The drain's `.libraries` tier calls `forceReload()` and starts
            // its own `load()`. Running that while the initial fan-out is
            // still in flight supersedes the very load this page is waiting
            // on — and library discovery posting `.libraries` makes it
            // likely, since the first load routinely outlasts the settle
            // guard (#236 § 8.1).
            //
            // The connection check is belt to the flag's braces, and matches
            // the initial-load task's id: a disconnect posts `.libraries`
            // (the list goes to `[]`), and a drain that runs against a nil
            // client blanks the raw arrays and parks every status at
            // `.loading` — the skeleton, forever.
            guard isEligible, session.isConnected, refreshCoordinator.isInitialLoadSettled else { return }

            // A player is up over this page. Its progress ticks post every
            // ~10s and `finishPlayback` posts again once the stop task
            // exists, so this task is woken when there is something to do —
            // polling for it here would spin the main actor for the whole
            // film.
            guard !refreshCoordinator.hasPlayingSession else { return }

            // Let the pop-settle finish and re-check: `tabSelection` clears
            // the outgoing path before it commits the switch, so eligibility
            // can be true for one frame while the viewer is leaving (§ 4).
            try? await Task.sleep(for: Self.settleGuard)
            guard !Task.isCancelled, isEligible else { return }

            // Never read server state while a stopped report is still landing.
            await refreshCoordinator.awaitPlaybackReporting()
            guard !Task.isCancelled else { return }

            // The token serializes this against a second drain and puts the
            // reason back if we are cancelled part-way (§ 8.1).
            guard let token = refreshCoordinator.beginDrain(now: .now) else { return }

            var outcome: HomeViewModel.LoadOutcome
            if token.reason == .watchState {
                outcome = await viewModel.refresh(token.reason)
            } else {
                // `load()` reads the library list `attach` last wrote, and
                // only the initial-load task attaches — which on visionOS
                // runs once for the whole session, since this page is never
                // torn down. Without this a library added mid-session would
                // never reach the reload it triggered (§ 8.5).
                viewModel.attach(
                    client: session.client,
                    libraries: connection.libraries,
                    cache: session.scopedCache,
                    userState: session.userState,
                )
                genreShelves.attach(client: session.client, libraries: connection.libraries)
                outcome = await viewModel.refresh(token.reason)
                outcome = await HomeViewModel.LoadOutcome.combine([outcome, genreShelves.reload()])
            }

            guard !Task.isCancelled else {
                refreshCoordinator.endDrain(token, outcome: .cancelled, now: .now)
                return
            }

            refreshCoordinator.endDrain(token, outcome: outcome.drainOutcome, now: .now)
        }
        .onChange(of: reduceMotion, initial: true) { _, isReduced in
            viewModel.setPaused(isReduced, reason: .reduceMotion)
            // The view model has no `@Environment`, so the view forwards the
            // accessibility setting for the shelf membership transactions.
            viewModel.reducesMotion = isReduced
        }
        // The empty state is reachable mid-session now, not only at launch: a
        // refresh can empty Home while the viewer is standing in it. If this
        // button does not take focus, the remote is dead (#69).
        .onChange(of: viewModel.isEmptyServer) { _, isEmpty in
            guard isEmpty else { return }
            // Deferred a tick on purpose: this fires in the same update that
            // swaps the tree, so the Settings button is not in the hierarchy
            // yet and a `@FocusState` write aimed at a view outside it is
            // dropped. Dropped here means a dead remote (#69).
            Task { @MainActor in
                await Task.yield()
                isEmptyStateActionFocused = true
            }
        }
        // The other way into the same single-focusable tree: a mid-session
        // sign-out or a dropped session swaps content for the disconnected
        // placeholder, whose only focusable view is the same Settings button.
        // Focus was on a card that no longer exists, and nothing else can take
        // it — a dead remote, the #69 class again.
        .onChange(of: session.isConnected) { _, isConnected in
            guard !isConnected else { return }
            // Deferred for the same reason as above: the button is not in the
            // hierarchy yet in the update that swaps the tree.
            Task { @MainActor in
                await Task.yield()
                isEmptyStateActionFocused = true
            }
        }
        .onChange(of: shelfRows) { old, new in
            // Fires in the update that removes the card, while `focusedCard`
            // still names it — before the engine has picked a neighbour.
            // Reconciling after the drain instead was too late: `refresh()`
            // publishes each lane as it lands, so the engine had already
            // moved on. A viewer who moved to a surviving card during the
            // refresh is left alone (§ 11.2); a card that vanished under them
            // lands where the rule says (§ 11.3), not where geometry happens
            // to put it.
            guard let focused = focusedCard,
                  !new.contains(where: { $0.id == focused.row && $0.itemIDs.contains(focused.item) })
            else { return }
            let next = HomeFocusReconciler.nextFocus(before: old, after: new, vanished: focused)
            land(next, deferred: next.map { target in !old.contains { $0.id == target.row } } ?? false)
        }
        .onChange(of: focusedCard) { _, target in
            // Only a positive card focus updates the stored target.
            // `focusedCard` also goes nil when Home is torn down, when a
            // cover or the sidebar takes focus, and transiently mid-move —
            // treating any of those as "the hero has focus" overwrites the
            // saved card and recreates the tab-return focus loss this task
            // exists to fix.
            guard let target else { return }
            ui.focusedItem = target
        }
        .onDisappear {
            viewModel.stopAutoAdvance()
            // Stored on both platforms, restored on tvOS only: visionOS keeps
            // the tab's own scroll state, so replaying it would fight it.
            ui.scrollOffset = scroll.offset
            ui.hasRestoredThisAppearance = false
        }
        .onAppear {
            viewModel.startAutoAdvance()
            guard !ui.hasRestoredThisAppearance else { return }
            ui.hasRestoredThisAppearance = true
            if !ui.focusIsOnHero, let stored = ui.focusedItem {
                // What survives, not what was stored — and `ui` records what
                // was actually restored, so a later reconcile reasons about
                // the card focus is really on.
                let target = restoredTarget(for: stored)
                ui.focusedItem = target
                ui.focusIsOnHero = target == nil
                if let target {
                    focusedCard = target
                    #if os(tvOS)
                        // Restore the region too. The card's own `.focused`
                        // binding does not imply the region binding, and
                        // leaving the region on `.hero` makes the next scroll
                        // snap yank the page back to the top.
                        focusedRegion = .shelves
                    #endif
                } else {
                    #if os(tvOS)
                        focusedRegion = .hero
                    #endif
                }
            }
            #if os(tvOS)
                if ui.scrollOffset > 0 {
                    scrollPosition.scrollTo(y: ui.scrollOffset)
                }
            #endif
        }
        .fullScreenCover(item: $playbackItem, onDismiss: { refreshCoordinator.post(.watchState) }) { target in
            if let client = session.client {
                PlaybackContainerView(
                    client: client,
                    item: target.item,
                    userState: session.userState,
                    mediaSourceId: target.mediaSourceId,
                    streamingBitrateCap: playbackPreferences.streamingQuality.bitsPerSecond,
                )
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
                // The wrapper drifts the lockup up faster than the page as it
                // exits, in lockstep with the backdrop fade — and back on the
                // way up. Offset only, never opacity (see
                // HomeHeroMotion.exitDrift). A wrapper so the per-tick
                // `progress` read stays out of this body, and the hero's
                // inputs stay unchanged during scroll so its body is skipped.
                HeroExitDrift(scroll: scroll, drift: HomeHeroMotion.exitDrift) {
                    HomeHeroSection(
                        items: viewModel.heroItems,
                        index: viewModel.heroIndex,
                        pagingDirection: viewModel.pagingDirection,
                        advanceRequests: viewModel.advanceRequests,
                        playTarget: viewModel.heroPlayTarget,
                        onPlay: { playbackItem = $0 },
                        onNext: {
                            viewModel.advanceHero()
                            viewModel.noteUserInteraction()
                        },
                        onSelect: { newIndex in
                            viewModel.selectHero(newIndex)
                            viewModel.noteUserInteraction()
                        },
                    )
                }
                #if os(tvOS)
                .focusSection()
                .focused($focusedRegion, equals: .hero)
                #endif

                // Everything below the fold shares one focus region so tvOS
                // treats it as a single page with a single scroll anchor.
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    HomeShelvesSection(
                        mergesContinueWatching: homePreferences.mergesContinueWatching,
                        mergedItems: viewModel.mergedContinueWatchingItems,
                        mergedStatus: viewModel.mergedContinueWatchingStatus,
                        resumeItems: viewModel.resumeItems,
                        nextUpItems: viewModel.nextUpItems,
                        latestShelves: viewModel.latestShelves,
                        resumeStatus: viewModel.resumeStatus,
                        nextUpStatus: viewModel.nextUpStatus,
                        latestStatus: viewModel.latestStatus,
                        // Headerless while the hero owns the screen; the
                        // title fades/slides in as the hero exits (always
                        // shown when there's no hero to defer to). Reads the
                        // stored reveal Bool — it flips at the threshold
                        // crossing only, so this body never sees the ramp.
                        showsResumeHeader: viewModel.currentHeroItem == nil
                            || scroll.revealsShelfHeader,
                        onPlay: { playbackItem = PlaybackRequest(item: $0) },
                        menu: { item in
                            ShelfMenuHandlers(
                                viewDetails: { pushMediaDetail?(item) },
                                setPlayed: { played in
                                    Task { await viewModel.setPlayed(played, for: item) }
                                },
                                setFavorite: { favorite in
                                    Task { await viewModel.setFavorite(favorite, for: item) }
                                },
                            )
                        },
                        onRetry: { Task { await viewModel.retryFailedSections() } },
                        focusBinding: $focusedCard,
                    )

                    GenreShelvesView(
                        shelves: genreShelves.shelves,
                        status: genreShelves.status,
                        onRetry: { Task { await genreShelves.retry() } },
                        focusBinding: $focusedCard,
                    )
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
                // The region is the honest hero-vs-shelves signal: it is set
                // by the page's own focus sections, not by a card
                // disappearing.
                ui.focusIsOnHero = region == .hero
                regionSnapTask = Task {
                    // Let the focus engine finish its own reveal scroll first,
                    // then assert the page anchor over it.
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    switch region {
                    case .hero:
                        guard scroll.offset > HomeHeroMotion.snapSlack else { return }
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
                        guard scroll.offset < shelvesAnchor - HomeHeroMotion.snapSlack else { return }
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
                if offset != scroll.offset {
                    scroll.offset = offset
                }
                // Map the offset to exit progress (dead-banding the focus
                // engine's settle); skip redundant writes so scrolling past
                // the fold stops invalidating.
                let progress = min(
                    max((offset - HomeHeroMotion.exitThreshold) / HomeHeroMotion.exitDistance, 0),
                    1,
                )
                if progress != scroll.progress {
                    scroll.progress = progress
                }
                // Stored so the shelves observe the flips, not the ramp.
                let revealsHeader = progress >= HomeHeroMotion.shelfHeaderReveal
                if revealsHeader != scroll.revealsShelfHeader {
                    scroll.revealsShelfHeader = revealsHeader
                }
                // Pause the carousel once the hero has fully exited; only
                // report boundary crossings so scrolling doesn't spam the
                // view model.
                let offscreen = progress >= 1
                if offscreen != scroll.isHeroOffscreen {
                    scroll.isHeroOffscreen = offscreen
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
        if session.client != nil, let item = viewModel.currentHeroItem {
            // The view model picks the image (an episode hero may ride its
            // own primary still instead of a backdrop — see
            // `heroBackdropURL(for:)`). The bridge owns the per-tick scroll
            // reads, so ticks re-run its body, not this one.
            HeroBackdropBridge(
                scroll: scroll,
                url: viewModel.heroBackdropURL(for: item),
                blurHash: viewModel.heroBackdropBlurHash(for: item),
                itemId: item.id,
                direction: viewModel.pagingDirection,
                generation: viewModel.pagingGeneration,
            )
        }
    }

    /// The shelf rows as ids, top to bottom — genre rows included, since they
    /// are focusable like any other and must not be skipped when focus falls
    /// through (§ 11.3). Row ids come from `HomeShelfRowID`, which the views
    /// bind from too, because a mismatch here is silent.
    private var shelfRows: [HomeFocusReconciler.Row] {
        var rows: [HomeFocusReconciler.Row] = []
        if homePreferences.mergesContinueWatching {
            rows.append(.init(
                id: HomeShelfRowID.continueWatching,
                itemIDs: viewModel.mergedContinueWatchingItems.map(\.id),
            ))
        } else {
            rows.append(.init(id: HomeShelfRowID.continueWatching, itemIDs: viewModel.resumeItems.map(\.id)))
            rows.append(.init(id: HomeShelfRowID.nextUp, itemIDs: viewModel.nextUpItems.map(\.id)))
        }
        rows.append(contentsOf: viewModel.latestShelves.map {
            .init(id: HomeShelfRowID.latest($0.library.id), itemIDs: $0.items.map(\.id))
        })
        rows.append(contentsOf: genreShelves.shelves.map {
            .init(id: HomeShelfRowID.genre($0.library.id), itemIDs: $0.genres)
        })
        return rows
    }

    /// Where focus lands for a stored card on a return, honouring rule 3
    /// when it is gone: the same row's first card if that row survives
    /// non-empty, otherwise nil for the hero.
    ///
    /// The stored id can name a card no view binds — a drain cancelled
    /// between applying its refresh and reconciling focus leaves exactly
    /// that — and writing a dropped id lands focus geometrically instead of
    /// where we said (§ 11.1).
    private func restoredTarget(for stored: ShelfFocusID) -> ShelfFocusID? {
        guard let row = shelfRows.first(where: { $0.id == stored.row }),
              let first = row.itemIDs.first
        else { return nil }
        return row.itemIDs.contains(stored.item) ? stored : ShelfFocusID(row: row.id, item: first)
    }

    /// Put focus on `target` — nil meaning the hero — and record where it
    /// went, so the page says where focus lands rather than letting the
    /// engine pick.
    ///
    /// - Parameter deferred: the target's row is new in this same update, so
    ///   its cards are not in the hierarchy yet and a write aimed at one is
    ///   dropped. One main-actor tick later they are.
    private func land(_ target: ShelfFocusID?, deferred: Bool) {
        ui.focusedItem = target
        ui.focusIsOnHero = target == nil
        #if os(tvOS)
            focusedRegion = target == nil ? .hero : .shelves
        #endif

        guard deferred, let target else {
            focusedCard = target
            return
        }
        Task { @MainActor in
            await Task.yield()
            focusedCard = target
        }
    }
}

/// Container geometry for the tvOS region snap (same shape as
/// MediaDetailView's — private there, so each page keeps its own copy).
private struct ScrollSnapMetrics: Equatable {
    var containerHeight: CGFloat
    var topInset: CGFloat
}

/// Home's per-scroll-tick values. @Observable, so a write invalidates only
/// the views whose bodies read the written property — never `HomeView.body`,
/// which reads only the stored `revealsShelfHeader` flips.
@Observable @MainActor
private final class HomeScrollState {
    /// Live scroll offset (`contentOffset.y + contentInsets.top`); the hero
    /// backdrop rides it so hero and backdrop slide up as one unit.
    var offset: CGFloat = 0

    /// Hero exit progress (0...1) mapped from the scroll offset — drives the
    /// lockup's extra drift and the backdrop fade, and reverses on the way
    /// back up. No `withAnimation`: the scroll itself provides continuity
    /// (and the region snap's animated scroll animates it for free).
    var progress: CGFloat = 0

    /// Progress has crossed `HomeHeroMotion.shelfHeaderReveal` — stored so
    /// header visibility observes the flips, not the ramp.
    var revealsShelfHeader = false

    /// Whether the hero has scrolled far enough away to pause the carousel.
    var isHeroOffscreen = false
}

/// Applies the hero's scroll-linked exit drift while keeping the per-tick
/// `progress` read out of the parent's body: the wrapped content is built by
/// the parent, so when a tick re-runs this body the content value is
/// unchanged and its body is skipped — only the offset moves.
private struct HeroExitDrift<Content: View>: View {
    let scroll: HomeScrollState
    let drift: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(y: scroll.progress * drift)
    }
}

/// Bridges the live scroll values into `HomeHeroBackdrop`'s plain inputs, so
/// the per-tick reads land in this leaf body instead of `HomeView`'s.
private struct HeroBackdropBridge: View {
    let scroll: HomeScrollState
    let url: URL?
    let blurHash: String?
    let itemId: String
    let direction: HomeViewModel.PagingDirection
    let generation: Int

    var body: some View {
        HomeHeroBackdrop(
            url: url,
            blurHash: blurHash,
            itemId: itemId,
            direction: direction,
            generation: generation,
            scrollOffset: scroll.offset,
            progress: scroll.progress,
        )
    }
}

#if DEBUG
    // With no client the session is disconnected, so this renders the
    // welcome empty state rather than shelves.
    #Preview("Standard", traits: .featuresEnvironment) {
        NavigationStack {
            HomeView(
                viewModel: HomeViewModel(),
                genreShelves: GenreShelvesViewModel(),
                ui: HomeUIState(),
                isEligible: true,
            )
        }
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        NavigationStack {
            HomeView(
                viewModel: HomeViewModel(),
                genreShelves: GenreShelvesViewModel(),
                ui: HomeUIState(),
                isEligible: true,
            )
        }
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        NavigationStack {
            HomeView(
                viewModel: HomeViewModel(),
                genreShelves: GenreShelvesViewModel(),
                ui: HomeUIState(),
                isEligible: true,
            )
        }
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        NavigationStack {
            HomeView(
                viewModel: HomeViewModel(),
                genreShelves: GenreShelvesViewModel(),
                ui: HomeUIState(),
                isEligible: true,
            )
        }
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        NavigationStack {
            HomeView(
                viewModel: HomeViewModel(),
                genreShelves: GenreShelvesViewModel(),
                ui: HomeUIState(),
                isEligible: true,
            )
        }
    }
#endif

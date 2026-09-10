import Foundation
import JellyfinKit
import Observation
import os
import SwiftUI

/// Loads the Home screen's sections and drives the hero carousel.
///
/// Each section (Continue Watching, Next Up, Recently Added) loads
/// independently and records its own status, so one failure degrades that
/// section deliberately instead of blanking the screen. The per-section load
/// methods are the seam where a future cache layer (#24) can hydrate before
/// refreshing from the network.
@Observable
@MainActor
public final class HomeViewModel {
    /// What a load or refresh actually did, for the refresh coordinator.
    ///
    /// Three cases, not two: a superseded or cancelled pass neither succeeded
    /// nor failed, and conflating it with either would let the drain start
    /// its floor on work that never happened, or re-post a reason forever
    /// (#236 § 8).
    public enum LoadOutcome: Equatable, Sendable {
        case succeeded
        case failed
        /// A newer generation took over, or the task was cancelled.
        case superseded

        /// Merge sibling loaders: any real failure wins, then supersession.
        static func combine(_ outcomes: [LoadOutcome]) -> LoadOutcome {
            if outcomes.contains(.failed) {
                return .failed
            }
            if outcomes.contains(.superseded) {
                return .superseded
            }
            return .succeeded
        }
    }

    /// Lifecycle of one Home section, independent of its siblings.
    public enum SectionStatus: Equatable {
        case loading
        case loaded
        /// Fetch succeeded but there is nothing to show (not an error).
        case empty
        case failed(String)

        var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    /// One "Recently Added" row for a single library.
    public struct LibraryShelf: Identifiable, Sendable {
        public let library: Library
        public let items: [MediaItem]
        public var id: String {
            library.id
        }
    }

    /// Every network fan-out, so a device round can count them from the
    /// console. Generation numbers and counts only; never an item.
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Home")

    /// Why the hero auto-advance timer is currently held.
    public enum PauseReason: Hashable {
        case focused
        case offscreen
        case reduceMotion
    }

    /// Library kinds that get a "Recently Added" row (audio, books, live TV
    /// are out of scope for Home).
    private static let latestCapable: Set<CollectionType> = [.movies, .tvshows, .boxsets]

    private static let resumeLimit = 16
    private static let nextUpLimit = 16
    /// Recently played episodes fetched for the merged lane's sort keys. A
    /// next-up series whose last watch predates this window sinks to the
    /// bottom of the merged lane — acceptable, it's stale by definition.
    private static let recentlyPlayedLimit = 60
    /// Global latest fetch feeding hero curation only (the shelves are per-library).
    /// The server applies this limit to the raw episode window BEFORE grouping
    /// (#279, verified against 10.11.11): a bulk add of one series' episodes
    /// ≥ the limit collapses the response to a single grouped entry — and the
    /// hero to one inert slide. 120 rides out an 80-episode drop with room to
    /// spare; curation still caps the marquee at `heroLimit`.
    private static let heroSourceLimit = 120
    private static let latestPerLibraryLimit = 26

    // MARK: - Outputs

    /// Raw section content as fetched. The public accessors below resolve
    /// through the user-state overlay at read time, so watched/favorite/
    /// progress changes render wherever an item appears without array
    /// surgery (#193).
    private var rawHeroItems: [MediaItem] = []
    private var rawResumeItems: [MediaItem] = []
    private var rawNextUpItems: [MediaItem] = []
    private var rawLatestShelves: [LibraryShelf] = []

    public var heroItems: [MediaItem] {
        userState.resolving(rawHeroItems)
    }

    /// Episode hero ids whose own primary still passed the
    /// `heroEpisodePrimaryMinWidth` check during curation. Members render
    /// that still as the hero backdrop; other episode heroes use the series
    /// backdrop (see `heroBackdropURL(for:)`).
    private var episodePrimaryHeroIds: Set<String> = []

    public var resumeItems: [MediaItem] {
        userState.resolving(rawResumeItems)
    }

    public var nextUpItems: [MediaItem] {
        userState.resolving(rawNextUpItems)
    }

    public var latestShelves: [LibraryShelf] {
        rawLatestShelves.map { LibraryShelf(library: $0.library, items: userState.resolving($0.items)) }
    }

    /// Each series' most recent episode play date — the sort keys that let
    /// next-up episodes (unwatched, so no `lastPlayedDate` of their own)
    /// interleave with resume items in the merged lane.
    public private(set) var seriesLastPlayedDates: [String: Date] = [:]

    /// Set by `HomeView` from `accessibilityReduceMotion` — the view model
    /// has no `@Environment`, so the view forwards the accessibility
    /// setting for the shelf membership transactions below.
    public var reducesMotion = false

    public private(set) var resumeStatus: SectionStatus = .loading
    public private(set) var nextUpStatus: SectionStatus = .loading
    /// Covers the hero curation source and the per-library rows.
    public private(set) var latestStatus: SectionStatus = .loading

    /// What the last `load()`'s network fan-out did. `load()` returns whether
    /// it *ran*; this says how it went.
    public private(set) var lastLoadOutcome: LoadOutcome = .succeeded

    public private(set) var heroIndex = 0

    /// What the hero Play button should start for the current hero item:
    /// the item itself for movies and episodes, the next-up (or first)
    /// episode for series, nil while resolving or for unplayable items
    /// (box sets).
    public private(set) var heroPlayTarget: MediaItem?

    /// True until the load settles EVERY section — all-or-nothing on
    /// purpose. Revealing content while the hero's source is still in
    /// flight hands tvOS focus to whichever shelf loaded first (an empty
    /// hero has no focusables), and the region snap then scrolls the hero
    /// away before it has anything to show.
    public var isInitialLoading: Bool {
        resumeStatus == .loading || nextUpStatus == .loading || latestStatus == .loading
    }

    /// Connected and fully loaded, but the server has nothing to show.
    public var isEmptyServer: Bool {
        resumeStatus == .empty && nextUpStatus == .empty && latestStatus == .empty
    }

    public var currentHeroItem: MediaItem? {
        rawHeroItems.indices.contains(heroIndex) ? userState.resolve(rawHeroItems[heroIndex]) : nil
    }

    /// The backdrop the hero should render for an item. Episodes whose
    /// primary still passed the width check ride that still; other episode
    /// heroes go straight to the inherited series backdrop (skipping
    /// `backdropURL`'s thumb fallback — a low-res thumb stretched across the
    /// marquee is exactly what the width rule exists to prevent). Everything
    /// else keeps the standard backdrop resolution.
    public func heroBackdropURL(for item: MediaItem) -> URL? {
        guard let client else { return nil }
        if episodePrimaryHeroIds.contains(item.id) {
            return client.getImageURL(itemId: item.id, imageType: .primary, maxWidth: 1920, maxHeight: nil)
        }
        if item.type == .episode,
           let parentId = item.parentArtwork?.backdropItemId,
           item.parentArtwork?.backdropImageTag != nil
        {
            return client.getImageURL(itemId: parentId, imageType: .backdrop, maxWidth: 1920, maxHeight: nil)
        }
        return client.backdropURL(for: item)
    }

    /// Placeholder hash matching `heroBackdropURL(for:)`'s image choice.
    /// (Inherited series backdrops carry no hash — `ParentArtwork` has none —
    /// so those render through the plain placeholder.)
    public func heroBackdropBlurHash(for item: MediaItem) -> String? {
        episodePrimaryHeroIds.contains(item.id)
            ? item.imageTags?.primaryBlurHash
            : item.backdropBlurHash
    }

    /// The single Continue Watching lane: resume and next-up interleaved by
    /// last-engagement recency. Computed so a preference flip re-renders from
    /// already-loaded state (≤32 items, recompute-on-read is trivial).
    public var mergedContinueWatchingItems: [MediaItem] {
        Self.mergeContinueWatching(
            resume: userState.resolving(rawResumeItems),
            nextUp: userState.resolving(rawNextUpItems),
            seriesLastPlayed: seriesLastPlayedDates,
            now: Date(),
        )
    }

    /// Section status for the merged lane. Partial results beat an error:
    /// items from either source render even when the other failed (the
    /// `needsLoad` re-arm already schedules a background refetch), so the
    /// lane only reports failure when a source failed AND nothing rendered.
    /// The `.loading` branch is covered by `isInitialLoading`'s skeleton in
    /// practice — `refreshUserState`/`retryFailedSections` never set it.
    public var mergedContinueWatchingStatus: SectionStatus {
        if resumeStatus == .loading || nextUpStatus == .loading {
            return .loading
        }
        if !rawResumeItems.isEmpty || !rawNextUpItems.isEmpty {
            return .loaded
        }
        if case .failed = resumeStatus {
            return resumeStatus
        }
        if case .failed = nextUpStatus {
            return nextUpStatus
        }
        return .empty
    }

    // MARK: - Configuration

    private let heroLimit: Int
    private let autoAdvanceInterval: Duration

    private var client: (any JellyfinClientProtocol)?
    private var libraries: [Library] = []
    private var cache: ScopedCache?

    /// The shared user-state overlay. A private fallback keeps the toggle
    /// and resolve semantics identical when a view constructs the model
    /// without one (previews, tests) — one code path, not two.
    private var userState = UserStateStore()

    /// Reload only when the connection or library set actually changes
    /// (mirrors `GenreShelvesViewModel`); a failed load re-arms this so the
    /// next appearance retries.
    private var needsLoad = true
    /// Whether a load has ever settled for the current client. Distinct from
    /// "the raw arrays are empty", which is content state: an empty server, a
    /// hero-only Home, and a genre-shelves-only Home have all completed a
    /// load and must never be told they are still finding out (#236 § 3).
    /// Reset only when the client is genuinely replaced.
    private var hasCompletedInitialLoad = false
    private var loadGeneration = 0

    private var advanceTask: Task<Void, Never>?
    private var pauseReasons: Set<PauseReason> = []
    private var playTargetTask: Task<Void, Never>?
    /// Resolved play targets by hero item id, so paging back to an item
    /// doesn't refetch its next-up episode.
    private var playTargets: [String: MediaItem] = [:]

    public init(heroLimit: Int = 10, autoAdvanceInterval: Duration = .seconds(7)) {
        self.heroLimit = heroLimit
        self.autoAdvanceInterval = autoAdvanceInterval
    }

    // MARK: - Loading

    /// Attach the client, library list, and cache (called by the view on
    /// appearance). Only an actual change schedules a reload.
    public func attach(
        client: (any JellyfinClientProtocol)?,
        libraries: [Library],
        cache: ScopedCache? = nil,
        userState: UserStateStore? = nil,
    ) {
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let librariesChanged = libraries.map(\.id) != self.libraries.map(\.id)
        self.client = client
        self.libraries = libraries
        self.cache = cache
        if let userState {
            self.userState = userState
        }
        if clientChanged {
            hasCompletedInitialLoad = false
        }
        if clientChanged || librariesChanged {
            needsLoad = true
        }
    }

    /// Load every section. No-op once loaded for the current client + libraries.
    ///
    /// - Returns: whether the load actually ran. A caller that stamps a
    ///   refresh timestamp needs this — a guarded-out call refreshed nothing
    ///   and must not mark the page fresh (#236 § 8).
    @discardableResult
    public func load() async -> Bool {
        guard needsLoad else { return false }
        needsLoad = false
        loadGeneration += 1
        let generation = loadGeneration

        stopAutoAdvance()
        playTargetTask?.cancel()
        heroPlayTarget = nil

        guard let client else {
            // No client means the session is still being established (or was
            // torn down) — Home is showing the skeleton or the disconnected
            // placeholder, never these statuses. Park them at `.loading`
            // rather than `.empty`: pre-marking empty made "Nothing here yet"
            // flash in the beat between connecting and the real load.
            rawHeroItems = []
            episodePrimaryHeroIds = []
            rawResumeItems = []
            rawNextUpItems = []
            rawLatestShelves = []
            seriesLastPlayedDates = [:]
            resumeStatus = .loading
            nextUpStatus = .loading
            latestStatus = .loading
            heroIndex = 0
            // Not `.succeeded`: nothing was confirmed, so a caller reading
            // this must not stamp the refresh floor. Leaving it stale handed
            // `completeInitialLoad(succeeded:)` the enum's default.
            lastLoadOutcome = .superseded
            return true
        }

        // Hydrate the whole page from the last successful load before any
        // network work, so a relaunch reveals content instead of the
        // skeleton. One blob applied in one turn: the all-or-nothing reveal
        // (`isInitialLoading`) fires exactly once with the hero populated,
        // which is what keeps default focus landing on the hero. The network
        // fan-out below then reconciles each section in place — the loaders
        // never set `.loading`, so the skeleton cannot return.
        var hydratedHeroIds: [String]?
        if rawResumeItems.isEmpty, rawNextUpItems.isEmpty, rawLatestShelves.isEmpty, let cache {
            let snapshot = await cache.read(CachedHomeSnapshot.self, key: .homeSnapshot)
            guard generation == loadGeneration else { return true }
            if let snapshot {
                rawResumeItems = snapshot.resume
                rawNextUpItems = snapshot.nextUp
                rawLatestShelves = snapshot.shelves.map { LibraryShelf(library: $0.library, items: $0.items) }
                rawHeroItems = snapshot.heroItems
                episodePrimaryHeroIds = Set(snapshot.episodePrimaryHeroIds)
                seriesLastPlayedDates = snapshot.seriesLastPlayedDates
                resumeStatus = snapshot.resume.isEmpty ? .empty : .loaded
                nextUpStatus = snapshot.nextUp.isEmpty ? .empty : .loaded
                latestStatus = (rawLatestShelves.isEmpty && rawHeroItems.isEmpty) ? .empty : .loaded
                settleHero(client: client, previousHeroIds: nil)
                hydratedHeroIds = rawHeroItems.map(\.id)
            }
        }
        // Park at `.loading` only before the first load has ever settled.
        // A warm reload — a library change, a floor re-check, a deep refresh
        // — has an established page and must reconcile in place; flipping
        // these makes `isInitialLoading` true and swaps the whole page for
        // the skeleton, which is what the #237 device review saw (#236 § 3).
        if hydratedHeroIds == nil, !hasCompletedInitialLoad {
            resumeStatus = .loading
            nextUpStatus = .loading
            latestStatus = .loading
        }

        Self.logger.debug("load fan-out, generation \(generation, privacy: .public), \(self.libraries.count, privacy: .public) libraries")
        // Sections resolve independently: each records its own items + status
        // as it completes, so a slow shelf never blocks its siblings.
        async let resumeOutcome = loadResume(client: client, generation: generation)
        async let nextUpOutcome = loadNextUp(client: client, generation: generation)
        async let latestOutcome = loadLatest(client: client, generation: generation)
        async let watchDatesOutcome = loadWatchDates(client: client, generation: generation)
        let outcomes = await [resumeOutcome, nextUpOutcome, latestOutcome, watchDatesOutcome]
        let outcome = LoadOutcome.combine(outcomes)
        Self.logger.debug("load generation \(generation, privacy: .public) outcomes resume/nextUp/latest/watchDates \(outcomes.map { String(describing: $0) }.joined(separator: "/"), privacy: .public); current generation \(self.loadGeneration, privacy: .public), cancelled \(Task.isCancelled, privacy: .public)")

        guard generation == loadGeneration else { return true }
        if Task.isCancelled {
            needsLoad = true
            return true
        }
        // Only a pass that actually ran to completion for the current
        // generation gets to record an outcome — a superseded or cancelled
        // pass returning here would let a stale `.succeeded` overwrite the
        // real result the still-running generation is about to report.
        lastLoadOutcome = outcome

        // On a hydrated load the previous ids are the snapshot's, so an
        // unchanged hero set skips the index reset and the marquee doesn't
        // yank under the viewer mid-reconcile.
        settleHero(client: client, previousHeroIds: hydratedHeroIds)
        hasCompletedInitialLoad = true

        if resumeStatus.isFailed || nextUpStatus.isFailed || latestStatus.isFailed {
            needsLoad = true
        } else if !needsLoad, let cache {
            // Every section is fresh from the network (a keep-on-failure
            // catch or partial shelf failure re-arms `needsLoad`, skipping
            // this): capture the page for the next launch's first frame.
            await cache.write(
                CachedHomeSnapshot(
                    resume: rawResumeItems,
                    nextUp: rawNextUpItems,
                    shelves: rawLatestShelves.map { CachedHomeSnapshot.Shelf(library: $0.library, items: $0.items) },
                    heroItems: rawHeroItems,
                    episodePrimaryHeroIds: Array(episodePrimaryHeroIds),
                    seriesLastPlayedDates: seriesLastPlayedDates,
                ),
                key: .homeSnapshot,
            )
        }
        return true
    }

    /// Re-arm the once-only guard so the next `load()` runs. Separate from
    /// `attach()`, which only re-arms on a changed client or library-id list
    /// — a refresh often has neither.
    public func forceReload() {
        needsLoad = true
    }

    /// Re-run only the sections currently marked `.failed` — the action
    /// behind the shelf notices' Retry buttons. The load methods never set
    /// `.loading`, so `isInitialLoading` can't flip the page back to the
    /// skeleton mid-retry, and untouched sections keep their content and
    /// focus undisturbed.
    public func retryFailedSections() async {
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration

        let shouldRetryResume = resumeStatus.isFailed
        let shouldRetryNextUp = nextUpStatus.isFailed
        let shouldRetryLatest = latestStatus.isFailed
        let heroIdsBefore = rawHeroItems.map(\.id)

        if shouldRetryResume {
            await loadResume(client: client, generation: generation)
        }
        if shouldRetryNextUp {
            await loadNextUp(client: client, generation: generation)
        }
        if shouldRetryLatest {
            await loadLatest(client: client, generation: generation)
        }
        // Not a section, so it has no failed status of its own to retry on —
        // but recovered resume/next-up items need fresh sort keys for the
        // merged lane, so it rides along with them (one deliberate fetch
        // beyond the "only failed sections" doctrine; invisible to statuses).
        if shouldRetryResume || shouldRetryNextUp {
            await loadWatchDates(client: client, generation: generation)
        }

        guard generation == loadGeneration else { return }

        // A recovered section can change the hero: latest rebuilds the
        // curation, and a recovered resume/next-up can offer a fallback
        // where there was none. `settleHero` skips the marquee reset when
        // the hero set didn't actually change.
        if shouldRetryLatest || rawHeroItems.isEmpty {
            settleHero(client: client, previousHeroIds: heroIdsBefore)
        }

        if resumeStatus.isFailed || nextUpStatus.isFailed || latestStatus.isFailed {
            needsLoad = true
        }
    }

    /// The hero settling shared by `load()` and `retryFailedSections()`:
    /// promote a fallback when curation produced nothing (the first
    /// backdrop-bearing resume/next-up item — single item, no rotation), then
    /// restart the marquee. Pass the previous hero ids to skip the index
    /// reset and auto-advance restart when the hero set is unchanged, so a
    /// shelf-only retry doesn't yank the marquee; `nil` always resets (a
    /// full load).
    private func settleHero(client: any JellyfinClientProtocol, previousHeroIds: [String]?) {
        if rawHeroItems.isEmpty {
            let fallback = (rawResumeItems + rawNextUpItems).first { client.backdropURL(for: $0) != nil }
            rawHeroItems = fallback.map { [$0] } ?? []
        }
        guard rawHeroItems.map(\.id) != previousHeroIds else { return }
        heroIndex = 0
        resolveHeroPlayTarget()
        startAutoAdvance()
    }

    /// Refresh just the watch-state sections after playback ends — resume and
    /// next-up move, and so do the unwatched counts on Recently Added's series
    /// cards. Reloading that row outright would rebuild the hero and flicker
    /// the marquee, so its counts are patched in place instead.
    ///
    /// - Returns: what the network actually did. The coordinator needs this,
    ///   not the UI's status: a warm-refresh failure keeps the lane
    ///   `.loaded` on purpose (#236 § 8.3).
    @discardableResult
    public func refreshUserState() async -> LoadOutcome {
        guard let client else { return .failed }
        loadGeneration += 1
        let generation = loadGeneration
        Self.logger.debug("refreshUserState fan-out, generation \(generation, privacy: .public)")
        async let resume = loadResume(client: client, generation: generation)
        async let nextUp = loadNextUp(client: client, generation: generation)
        async let watchDates = loadWatchDates(client: client, generation: generation)
        async let counts = refreshContainerCounts(client: client, generation: generation)
        return await LoadOutcome.combine([resume, nextUp, watchDates, counts])
    }

    /// Refresh at the given depth, reporting what the network actually did.
    ///
    /// The tiers are cumulative and deliberately asymmetric: `watchState`
    /// leaves the hero alone, because a silent re-check that restarts the
    /// marquee under an idle viewer reads as a bug rather than freshness.
    public func refresh(_ reason: RefreshReason) async -> LoadOutcome {
        Self.logger.debug("refresh \(String(describing: reason), privacy: .public)")
        switch reason {
        case .watchState:
            return await refreshUserState()
        case .libraries, .deep:
            forceReload()
            // `load()` increments the generation first thing, so this is the
            // pass we are about to run. A superseded or cancelled pass leaves
            // `lastLoadOutcome` to the generation that won, and reporting that
            // value here would let the drain retire a reason nothing served.
            let generation = loadGeneration + 1
            await load()
            guard generation == loadGeneration, !Task.isCancelled else { return .superseded }
            return lastLoadOutcome
        }
    }

    /// Re-read the unwatched counts behind Recently Added's series cards.
    ///
    /// Both the count badge and the progress band read `unplayedItemCount`,
    /// and watching an episode moves it — but the episode is its own item, so
    /// the user-state overlay (keyed by item id) never reaches its parent.
    /// One `ids=` fetch covers every series on screen; the cards keep their
    /// identity, so nothing re-enters the focus engine.
    @discardableResult
    private func refreshContainerCounts(client: any JellyfinClientProtocol, generation: Int) async -> LoadOutcome {
        let ids = Set(rawLatestShelves.flatMap(\.items).filter { $0.type == .series }.map(\.id))
        // Nothing was attempted, so nothing failed.
        guard !ids.isEmpty else { return .succeeded }

        do {
            let refreshed = try await client.getMediaItems(ids: Array(ids))
            guard generation == loadGeneration else { return .superseded }

            let counts = Dictionary(
                refreshed.map { ($0.id, $0.userData?.unplayedItemCount) },
                uniquingKeysWith: { first, _ in first },
            )
            rawLatestShelves = rawLatestShelves.map { shelf in
                LibraryShelf(
                    library: shelf.library,
                    items: shelf.items.map { item in
                        guard let count = counts[item.id] else { return item }
                        return item.settingUnplayedItemCount(count)
                    },
                )
            }
            return .succeeded
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return .superseded }
            Self.logger.debug("refreshContainerCounts failed: \(PlaybackLog.error(error), privacy: .public)")
            // The badges just stay stale — no `SectionStatus` covers counts,
            // so this never blanks anything — but the coordinator still needs
            // to know the fetch genuinely failed.
            return .failed
        }
    }

    // MARK: - User-Data Actions

    /// Apply a watched-state change from a shelf card's menu through the
    /// user-state overlay (every section showing the item updates at once);
    /// the server's acknowledgment commits it, a failure withdraws it.
    /// The confirm bumps `UserStateStore.mutationRevision`, which RootView
    /// turns into a `.watchState` post — so lane membership is reconciled by
    /// the drain, once, rather than by a second fan-out from here (#236).
    public func setPlayed(_ played: Bool, for item: MediaItem) async {
        guard let client else { return }
        let token = userState.beginPlayedToggle(itemID: item.id, target: played)
        do {
            if played {
                try await client.markPlayed(itemId: item.id)
            } else {
                try await client.markUnplayed(itemId: item.id)
            }
            userState.confirm(token)
        } catch {
            userState.revert(token)
        }
    }

    /// Apply a favorite change from a shelf card's menu; same pending-
    /// toggle lifecycle. Favorites don't move lane membership, so no
    /// refresh.
    public func setFavorite(_ favorite: Bool, for item: MediaItem) async {
        guard let client else { return }
        let token = userState.beginFavoriteToggle(itemID: item.id, target: favorite)
        do {
            if favorite {
                try await client.markFavorite(itemId: item.id)
            } else {
                try await client.unmarkFavorite(itemId: item.id)
            }
            userState.confirm(token)
        } catch {
            userState.revert(token)
        }
    }

    /// Animates a shelf membership write with the exit curve, unless Reduce
    /// Motion is on — one branch, so the three loaders below don't each
    /// repeat the check.
    private func animatingMembership(_ body: () -> Void) {
        if reducesMotion {
            body()
        } else {
            withAnimation(HomeHeroMotion.shelfItemExit) {
                body()
            }
        }
    }

    @discardableResult
    private func loadResume(client: any JellyfinClientProtocol, generation: Int) async -> LoadOutcome {
        do {
            let items = try await client.getResumeItems(limit: Self.resumeLimit)
            guard generation == loadGeneration else { return .superseded }
            animatingMembership {
                rawResumeItems = items
            }
            resumeStatus = items.isEmpty ? .empty : .loaded
            return .succeeded
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return .superseded }
            Self.logger.debug("loadResume failed: \(PlaybackLog.error(error), privacy: .public)")
            if rawResumeItems.isEmpty {
                resumeStatus = .failed(error.localizedDescription)
            } else {
                // Keep the rendered lane — hydrated content offline, or the
                // previous items when a post-playback refresh fails —
                // and re-arm so the next appearance retries. Blanking a
                // rendered lane over a refresh failure reads as data loss.
                resumeStatus = .loaded
                needsLoad = true
            }
            return .failed
        }
    }

    @discardableResult
    private func loadNextUp(client: any JellyfinClientProtocol, generation: Int) async -> LoadOutcome {
        do {
            let items = try await client.getNextUpItems(limit: Self.nextUpLimit)
            guard generation == loadGeneration else { return .superseded }
            animatingMembership {
                rawNextUpItems = items
            }
            nextUpStatus = items.isEmpty ? .empty : .loaded
            return .succeeded
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return .superseded }
            Self.logger.debug("loadNextUp failed: \(PlaybackLog.error(error), privacy: .public)")
            if rawNextUpItems.isEmpty {
                nextUpStatus = .failed(error.localizedDescription)
            } else {
                // Same keep-and-re-arm rule as `loadResume`
                nextUpStatus = .loaded
                needsLoad = true
            }
            return .failed
        }
    }

    @discardableResult
    private func loadWatchDates(client: any JellyfinClientProtocol, generation: Int) async -> LoadOutcome {
        do {
            let episodes = try await client.getRecentlyPlayedEpisodes(limit: Self.recentlyPlayedLimit)
            guard generation == loadGeneration else { return .superseded }
            seriesLastPlayedDates = Self.seriesLastPlayedMap(from: episodes)
            return .succeeded
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return .superseded }
            Self.logger.debug("loadWatchDates failed: \(PlaybackLog.error(error), privacy: .public)")
            // A failure keeps the previous (possibly stale) map — stale
            // dates still order better than sinking every next-up item to
            // the bottom — and never fails a section (there's no
            // `SectionStatus` for this), but the coordinator still needs to
            // know the fetch genuinely failed.
            return .failed
        }
    }

    @discardableResult
    private func loadLatest(client: any JellyfinClientProtocol, generation: Int) async -> LoadOutcome {
        async let heroSource = client.getLatestItems(libraryId: nil, limit: Self.heroSourceLimit)

        let capable = libraries.filter { library in
            library.collectionType.map(Self.latestCapable.contains) ?? false
        }
        let (shelves, shelfError) = await Self.buildLatestShelves(
            client: client,
            libraries: capable,
            limit: Self.latestPerLibraryLimit,
        )

        do {
            let latest = try await heroSource
            var curated = Self.curateHeroItems(
                from: latest,
                hasBackdrop: { client.backdropURL(for: $0) != nil },
                limit: heroLimit,
            )
            let primaryIds = await Self.resolveEpisodePrimaryHeroIds(
                in: curated,
                minWidth: Self.heroEpisodePrimaryMinWidth,
                imageInfo: client.getImageInfo(itemId:),
            )
            // An episode whose still failed the width check needs the series
            // backdrop behind it; with neither it can't carry the hero.
            curated.removeAll { $0.type == .episode && !primaryIds.contains($0.id) && !Self.hasSeriesBackdrop($0) }
            curated = await Self.resolvingHeroMediaSources(in: curated, client: client)

            guard generation == loadGeneration else { return .superseded }
            animatingMembership {
                rawLatestShelves = shelves
            }
            // The hero has its own motion (page-turn choreography, not shelf
            // membership) and must not inherit the shelf-exit transaction
            // just because it lands in the same main-actor tick as the write
            // above.
            var heroTransaction = Transaction()
            heroTransaction.disablesAnimations = true
            withTransaction(heroTransaction) {
                episodePrimaryHeroIds = primaryIds
                rawHeroItems = curated
            }
            // A partial library failure still shows what survived, but re-arms
            // the load so the next appearance refetches the missing rows.
            // (`load()` only ever re-sets this to true at its end, so setting
            // it mid-flight is safe.)
            if shelfError != nil {
                needsLoad = true
            }
            if shelves.isEmpty, let shelfError {
                // The hero curation isn't the section's content; when every
                // row failed, that's a failed section even with a live hero.
                latestStatus = .failed(shelfError)
            } else {
                latestStatus = (shelves.isEmpty && rawHeroItems.isEmpty) ? .empty : .loaded
            }
            // A surviving-shelves failure keeps `latestStatus` at `.loaded` on
            // purpose (a rendered row must not blank), so the outcome has to
            // carry what the status deliberately hides.
            if let shelfError {
                Self.logger.debug("loadLatest partial failure: \(shelfError, privacy: .public)")
            }
            return shelfError != nil ? .failed : .succeeded
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return .superseded }
            Self.logger.debug("loadLatest failed: \(PlaybackLog.error(error), privacy: .public)")
            if rawLatestShelves.isEmpty, rawHeroItems.isEmpty {
                rawLatestShelves = shelves
                episodePrimaryHeroIds = []
                rawHeroItems = []
                if shelfError != nil {
                    needsLoad = true
                }
                // The per-library rows stand on their own; only report failure
                // when nothing in the section survived.
                latestStatus = shelves.isEmpty ? .failed(error.localizedDescription) : .loaded
            } else {
                // A hydrated hero and rows are already rendering; keep them
                // whole rather than swapping in a partial fresh set with a
                // blanked hero, and re-arm so the next appearance retries.
                latestStatus = .loaded
                needsLoad = true
            }
            // The hero source itself failed here, regardless of how the
            // per-library shelves fared — always a real failure, never
            // superseded (the guard above already routed that case out).
            return .failed
        }
    }

    /// A cancelled request is a cancellation, not a failure: the task was
    /// superseded (a newer load, a dismissed page), and painting "Couldn't
    /// load" over it reads as data loss (#236 § 8.4).
    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// One "Recently Added" fetch per qualifying library, concurrently, in
    /// library order. Empty libraries simply contribute no row; failed ones
    /// also report back (as the first failure's description, in library
    /// order) so `loadLatest` can surface the error and re-arm a retry
    /// instead of silently blanking the rows.
    private nonisolated static func buildLatestShelves(
        client: any JellyfinClientProtocol,
        libraries: [Library],
        limit: Int,
    ) async -> (shelves: [LibraryShelf], firstError: String?) {
        let byIndex = await withTaskGroup(of: (Int, Result<LibraryShelf?, Error>).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    do {
                        var items = try await client.getLatestItems(libraryId: library.id, limit: limit)
                        if library.collectionType == .tvshows {
                            items = await resolvingSeriesEntries(client: client, items: items)
                        }
                        return (index, .success(items.isEmpty ? nil : LibraryShelf(library: library, items: items)))
                    } catch {
                        // A cancelled request is a cancellation, not a failure;
                        // drop it so the caller doesn't record it as `firstError`.
                        guard !Task.isCancelled, !Self.isCancellation(error) else { return (index, .success(nil)) }
                        return (index, .failure(error))
                    }
                }
            }
            var results: [Int: Result<LibraryShelf?, Error>] = [:]
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }

        var shelves: [LibraryShelf] = []
        var firstError: String?
        for index in libraries.indices {
            switch byIndex[index] {
            case let .success(shelf?):
                shelves.append(shelf)
            case let .failure(error):
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            case .success(nil), .none:
                break
            }
        }
        return (shelves, firstError)
    }

    /// TV "Recently Added" entries can be single episodes — the server only
    /// groups multi-episode additions into their series. An episode lockup
    /// is wrong for a poster shelf (portrait-cropped still, episode-title
    /// caption), so swap each for its series item: poster, series name,
    /// year, and the server's unplayed count for the unwatched badge.
    /// Series appearing more than once collapse into one entry.
    private nonisolated static func resolvingSeriesEntries(
        client: any JellyfinClientProtocol,
        items: [MediaItem],
    ) async -> [MediaItem] {
        var seenSeries: Set<String> = []
        var resolved: [MediaItem] = []
        for item in items {
            if item.type == .episode, let seriesId = item.seriesId {
                guard seenSeries.insert(seriesId).inserted else { continue }
                let series = try? await client.getMediaItem(itemId: seriesId)
                resolved.append(series ?? item)
            } else {
                if item.type == .series {
                    guard seenSeries.insert(item.id).inserted else { continue }
                }
                resolved.append(item)
            }
        }
        return resolved
    }

    // MARK: - Continue Watching merge

    /// Collapse recently played episodes into each series' most recent play
    /// date. Episodes without a series or a play date contribute nothing.
    nonisolated static func seriesLastPlayedMap(from episodes: [MediaItem]) -> [String: Date] {
        var map: [String: Date] = [:]
        for episode in episodes {
            guard let seriesId = episode.seriesId,
                  let lastPlayed = episode.userData?.lastPlayedDate
            else { continue }
            map[seriesId] = max(map[seriesId] ?? .distantPast, lastPlayed)
        }
        return map
    }

    /// How recently a series must have been played for a new episode's
    /// arrival date to count as engagement in the merged lane. Keeps a fresh
    /// weekly episode ranked by its arrival while a new season of a show
    /// abandoned months ago stays put — that's Recently Added's job.
    nonisolated static let newEpisodeBoostWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Merge resume and next-up into one lane, most recent event first — a
    /// play, or a new episode arriving for a show in active rotation.
    /// Resume items sort by their own `lastPlayedDate`. Next-up episodes sort
    /// by their series' last-watched date from `seriesLastPlayed` (a next-up
    /// episode is unwatched, so it has no play date of its own), raised to
    /// the episode's `dateCreated` when the series was played within
    /// `newEpisodeBoostWindow` of `now` — so the weekly show whose episode
    /// just landed outranks a show merely watched yesterday. Items with no
    /// date sink to the bottom. Ties keep source order with resume before
    /// next-up (Swift's sort stability is unspecified, so the original index
    /// is an explicit tiebreaker). Dedupes by id — the server already keeps
    /// the sets disjoint (`enableResumable = false`), this is belt-and-braces.
    nonisolated static func mergeContinueWatching(
        resume: [MediaItem],
        nextUp: [MediaItem],
        seriesLastPlayed: [String: Date],
        now: Date,
    ) -> [MediaItem] {
        let keyed =
            resume.enumerated().map { index, item in
                (item: item, date: item.userData?.lastPlayedDate ?? .distantPast, index: index)
            }
            + nextUp.enumerated().map { index, item in
                let lastPlayed = item.seriesId.flatMap { seriesLastPlayed[$0] } ?? .distantPast
                let isActivelyWatched = now.timeIntervalSince(lastPlayed) <= newEpisodeBoostWindow
                let date = if isActivelyWatched, let added = item.dateCreated {
                    max(lastPlayed, added)
                } else {
                    lastPlayed
                }
                return (item: item, date: date, index: resume.count + index)
            }

        var seenIds: Set<String> = []
        return keyed
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.index < $1.index }
            .compactMap { seenIds.insert($0.item.id).inserted ? $0.item : nil }
    }

    // MARK: - Hero curation

    /// Minimum pixel width for an episode's primary still to carry the hero
    /// backdrop; narrower stills fall back to the series backdrop instead of
    /// stretching across the marquee.
    nonisolated static let heroEpisodePrimaryMinWidth = 1080

    /// Distills the latest additions into a small marquee set: feature-worthy
    /// types only, must have hero-capable artwork, one slot per title/series,
    /// newest first.
    ///
    /// Episodes ride in on their series' behalf — a lone new arrival of a
    /// followed show is often the most relevant thing on the server (multi-
    /// episode additions come back from `/Latest` grouped as a series item
    /// instead). An episode needs a series to dedupe under, plus either its
    /// own primary still (width-checked afterwards by
    /// `episodePrimaryHeroIds`) or an inherited series backdrop.
    nonisolated static func curateHeroItems(
        from latest: [MediaItem],
        hasBackdrop: (MediaItem) -> Bool,
        limit: Int,
    ) -> [MediaItem] {
        var seenIds: Set<String> = []
        var seenSeries: Set<String> = []
        var curated: [MediaItem] = []

        for item in latest {
            guard curated.count < limit else { break }
            switch item.type {
            case .movie, .series, .boxSet:
                guard hasBackdrop(item) else { continue }
            case .episode:
                guard item.seriesId != nil,
                      item.imageTags?.primary != nil || Self.hasSeriesBackdrop(item)
                else { continue }
            default:
                continue
            }
            guard seenIds.insert(item.id).inserted else { continue }

            let seriesKey = item.type == .series ? item.id : item.seriesId
            if let seriesKey {
                guard seenSeries.insert(seriesKey).inserted else { continue }
            }
            curated.append(item)
        }
        return curated
    }

    /// Whether the episode inherits a series backdrop it can fall back to.
    private nonisolated static func hasSeriesBackdrop(_ item: MediaItem) -> Bool {
        item.parentArtwork?.backdropItemId != nil && item.parentArtwork?.backdropImageTag != nil
    }

    /// Fill the curated heroes' `mediaSources` in one ids= batch. The bulk
    /// `/Latest` fetch omits the field (its window is `heroSourceLimit` items,
    /// #279), so the version picker's sources (#147) come from this pass.
    /// Only the source list merges in — a wholesale item swap would trade
    /// `/Latest`'s grouped-series entries (`childCount` = new-episode count,
    /// the "N New Episodes" label) for the plainly-fetched series. A failed
    /// fetch degrades the picker to sourceless heroes, never the section.
    private nonisolated static func resolvingHeroMediaSources(
        in curated: [MediaItem],
        client: any JellyfinClientProtocol,
    ) async -> [MediaItem] {
        guard !curated.isEmpty,
              let fetched = try? await client.getMediaItems(ids: curated.map(\.id))
        else { return curated }

        let sourcesById = Dictionary(
            fetched.map { ($0.id, $0.mediaSources) },
            uniquingKeysWith: { first, _ in first },
        )
        return curated.map { item in
            guard let sources = sourcesById[item.id], sources != nil else { return item }
            var enriched = item
            enriched.mediaSources = sources
            return enriched
        }
    }

    /// The ids of curated episodes whose own primary still is wide enough
    /// (`minWidth`) to carry the marquee, checked concurrently against the
    /// server's stored dimensions. A failed lookup — or one reporting no
    /// primary width — just leaves the episode on its series-backdrop
    /// fallback, so this never fails the section.
    nonisolated static func resolveEpisodePrimaryHeroIds(
        in items: [MediaItem],
        minWidth: Int,
        imageInfo: @escaping @Sendable (String) async throws -> [ItemImageInfo],
    ) async -> Set<String> {
        let candidates = items.filter { $0.type == .episode && $0.imageTags?.primary != nil }
        guard !candidates.isEmpty else { return [] }

        return await withTaskGroup(of: String?.self) { group in
            for item in candidates {
                group.addTask {
                    guard let infos = try? await imageInfo(item.id),
                          let width = infos.first(where: { $0.imageType == .primary })?.width
                    else { return nil }
                    return width >= minWidth ? item.id : nil
                }
            }
            var ids: Set<String> = []
            for await id in group {
                if let id {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    // MARK: - Hero paging

    /// Which way the last page turn went — the view aims the backdrop slide
    /// and the post-turn focus landing (advance → Next, retreat → Play) off
    /// this. Set before `heroIndex` mutates so observers see them together.
    public enum PagingDirection {
        case forward
        case backward
    }

    public private(set) var pagingDirection: PagingDirection = .forward

    /// Monotonic page-turn counter: the backdrop stacks the incoming image
    /// above the outgoing one by this (index alone can't — wrapping from the
    /// last page back to 0 would order the new image underneath).
    public private(set) var pagingGeneration = 0

    /// Bumped when the auto-advance timer wants a page turn. The view
    /// answers by fading the content out and then calling `advanceHero()` —
    /// mutating the index directly from here would snap the new page in
    /// before the fade choreography could hide it.
    public private(set) var advanceRequests = 0

    /// Advance to the next hero item (wrapping). Used by the timer and the
    /// hero's "next" button.
    public func advanceHero() {
        guard rawHeroItems.count > 1 else { return }
        pagingDirection = .forward
        pagingGeneration += 1
        heroIndex = (heroIndex + 1) % rawHeroItems.count
        resolveHeroPlayTarget()
    }

    /// Jump to a specific hero item — the paged tab view reports user-driven
    /// page turns (edge navigation, swipes) here. Native paging never wraps,
    /// so plain comparison gives the direction.
    public func selectHero(_ newIndex: Int) {
        guard rawHeroItems.indices.contains(newIndex), newIndex != heroIndex else { return }
        pagingDirection = newIndex > heroIndex ? .forward : .backward
        pagingGeneration += 1
        heroIndex = newIndex
        resolveHeroPlayTarget()
    }

    /// A manual page should earn a full interval before the next auto-advance.
    public func noteUserInteraction() {
        guard advanceTask != nil else { return }
        stopAutoAdvance()
        startAutoAdvance()
    }

    /// Hold or release the auto-advance timer for one reason (focus, scrolled
    /// away, Reduce Motion); the timer runs only while no reason is active.
    public func setPaused(_ paused: Bool, reason: PauseReason) {
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        if pauseReasons.isEmpty {
            startAutoAdvance()
        } else {
            stopAutoAdvance()
        }
    }

    public func startAutoAdvance() {
        guard advanceTask == nil, rawHeroItems.count > 1, pauseReasons.isEmpty else { return }
        advanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.autoAdvanceInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.advanceRequests += 1
            }
        }
    }

    public func stopAutoAdvance() {
        advanceTask?.cancel()
        advanceTask = nil
    }

    // MARK: - Hero play target

    /// Resolve what Play should start for the current hero item. Movies and
    /// episodes play directly (an episode hero IS the thing to play — no
    /// next-up resolution); series resolve to their next-up episode (or first
    /// episode for never-started series, per `getNextUpEpisode`); box sets
    /// don't play — their details button is the way in.
    private func resolveHeroPlayTarget() {
        playTargetTask?.cancel()
        playTargetTask = nil
        heroPlayTarget = nil

        guard let item = currentHeroItem else { return }
        if let cached = playTargets[item.id] {
            heroPlayTarget = cached
            return
        }

        switch item.type {
        case .movie, .episode:
            playTargets[item.id] = item
            heroPlayTarget = item
        case .series:
            guard let client else { return }
            playTargetTask = Task { [weak self] in
                // `try?` is enrichment, not swallowing: a nil target just
                // disables the hero Play button, and failures are never
                // cached (`playTargets` is written on success only), so
                // paging back to the item refetches.
                let next = try? await client.getNextUpEpisode(seriesId: item.id)
                guard !Task.isCancelled, let self, self.currentHeroItem?.id == item.id else { return }
                if let next {
                    self.playTargets[item.id] = next
                }
                self.heroPlayTarget = next
            }
        default:
            break
        }
    }
}

extension HomeViewModel.LoadOutcome {
    /// A superseded pass is a cancellation as far as the drain is
    /// concerned: nothing was confirmed, and the reason is still owed.
    var drainOutcome: ContentRefreshCoordinator.DrainOutcome {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .superseded: .cancelled
        }
    }
}

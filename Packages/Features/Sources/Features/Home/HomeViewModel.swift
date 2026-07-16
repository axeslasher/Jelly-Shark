import Foundation
import JellyfinKit
import Observation

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
    private static let heroSourceLimit = 16
    private static let latestPerLibraryLimit = 26

    // MARK: - Outputs

    public private(set) var heroItems: [MediaItem] = []
    public private(set) var resumeItems: [MediaItem] = []
    public private(set) var nextUpItems: [MediaItem] = []
    public private(set) var latestShelves: [LibraryShelf] = []

    /// Each series' most recent episode play date — the sort keys that let
    /// next-up episodes (unwatched, so no `lastPlayedDate` of their own)
    /// interleave with resume items in the merged lane.
    public private(set) var seriesLastPlayedDates: [String: Date] = [:]

    public private(set) var resumeStatus: SectionStatus = .loading
    public private(set) var nextUpStatus: SectionStatus = .loading
    /// Covers the hero curation source and the per-library rows.
    public private(set) var latestStatus: SectionStatus = .loading

    public private(set) var heroIndex = 0

    /// What the hero Play button should start for the current hero item:
    /// the item itself for movies, the next-up (or first) episode for series,
    /// nil while resolving or for unplayable items (box sets).
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
        heroItems.indices.contains(heroIndex) ? heroItems[heroIndex] : nil
    }

    /// The single Continue Watching lane: resume and next-up interleaved by
    /// last-engagement recency. Computed so a preference flip re-renders from
    /// already-loaded state (≤32 items, recompute-on-read is trivial).
    public var mergedContinueWatchingItems: [MediaItem] {
        Self.mergeContinueWatching(
            resume: resumeItems,
            nextUp: nextUpItems,
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
        if !resumeItems.isEmpty || !nextUpItems.isEmpty {
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

    /// Reload only when the connection or library set actually changes
    /// (mirrors `GenreShelvesViewModel`); a failed load re-arms this so the
    /// next appearance retries.
    private var needsLoad = true
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

    /// Attach the client and library list (called by the view on appearance).
    /// Only an actual change schedules a reload.
    public func attach(client: (any JellyfinClientProtocol)?, libraries: [Library]) {
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let librariesChanged = libraries.map(\.id) != self.libraries.map(\.id)
        self.client = client
        self.libraries = libraries
        if clientChanged || librariesChanged {
            needsLoad = true
        }
    }

    /// Load every section. No-op once loaded for the current client + libraries.
    public func load() async {
        guard needsLoad else { return }
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
            heroItems = []
            resumeItems = []
            nextUpItems = []
            latestShelves = []
            seriesLastPlayedDates = [:]
            resumeStatus = .loading
            nextUpStatus = .loading
            latestStatus = .loading
            heroIndex = 0
            return
        }

        resumeStatus = .loading
        nextUpStatus = .loading
        latestStatus = .loading

        // Sections resolve independently: each records its own items + status
        // as it completes, so a slow shelf never blocks its siblings.
        async let resume: Void = loadResume(client: client, generation: generation)
        async let nextUp: Void = loadNextUp(client: client, generation: generation)
        async let latest: Void = loadLatest(client: client, generation: generation)
        async let watchDates: Void = loadWatchDates(client: client, generation: generation)
        _ = await (resume, nextUp, latest, watchDates)

        guard generation == loadGeneration else { return }
        if Task.isCancelled {
            needsLoad = true
            return
        }

        settleHero(client: client, previousHeroIds: nil)

        if resumeStatus.isFailed || nextUpStatus.isFailed || latestStatus.isFailed {
            needsLoad = true
        }
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
        let heroIdsBefore = heroItems.map(\.id)

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
        if shouldRetryLatest || heroItems.isEmpty {
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
        if heroItems.isEmpty {
            let fallback = (resumeItems + nextUpItems).first { client.backdropURL(for: $0) != nil }
            heroItems = fallback.map { [$0] } ?? []
        }
        guard heroItems.map(\.id) != previousHeroIds else { return }
        heroIndex = 0
        resolveHeroPlayTarget()
        startAutoAdvance()
    }

    /// Refresh just the watch-state sections after playback ends — resume and
    /// next-up move, but the hero and Recently Added rows don't, so this skips
    /// them (no marquee flicker on dismiss).
    public func refreshUserState() async {
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        async let resume: Void = loadResume(client: client, generation: generation)
        async let nextUp: Void = loadNextUp(client: client, generation: generation)
        async let watchDates: Void = loadWatchDates(client: client, generation: generation)
        _ = await (resume, nextUp, watchDates)
    }

    private func loadResume(client: any JellyfinClientProtocol, generation: Int) async {
        do {
            let items = try await client.getResumeItems(limit: Self.resumeLimit)
            guard generation == loadGeneration else { return }
            resumeItems = items
            resumeStatus = items.isEmpty ? .empty : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            resumeItems = []
            resumeStatus = .failed(error.localizedDescription)
        }
    }

    private func loadNextUp(client: any JellyfinClientProtocol, generation: Int) async {
        do {
            let items = try await client.getNextUpItems(limit: Self.nextUpLimit)
            guard generation == loadGeneration else { return }
            nextUpItems = items
            nextUpStatus = items.isEmpty ? .empty : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            nextUpItems = []
            nextUpStatus = .failed(error.localizedDescription)
        }
    }

    private func loadWatchDates(client: any JellyfinClientProtocol, generation: Int) async {
        // `try?` is enrichment, not swallowing: the dates only order the
        // merged lane, so a failure keeps the previous (possibly stale) map —
        // stale dates still order better than sinking every next-up item to
        // the bottom — and never fails a section.
        guard let episodes = try? await client.getRecentlyPlayedEpisodes(limit: Self.recentlyPlayedLimit) else {
            return
        }
        guard generation == loadGeneration else { return }
        seriesLastPlayedDates = Self.seriesLastPlayedMap(from: episodes)
    }

    private func loadLatest(client: any JellyfinClientProtocol, generation: Int) async {
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
            guard generation == loadGeneration else { return }
            latestShelves = shelves
            heroItems = Self.curateHeroItems(
                from: latest,
                hasBackdrop: { client.backdropURL(for: $0) != nil },
                limit: heroLimit,
            )
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
                latestStatus = (shelves.isEmpty && heroItems.isEmpty) ? .empty : .loaded
            }
        } catch {
            guard generation == loadGeneration else { return }
            latestShelves = shelves
            heroItems = []
            if shelfError != nil {
                needsLoad = true
            }
            // The per-library rows stand on their own; only report failure
            // when nothing in the section survived.
            latestStatus = shelves.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
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

    /// Distills the latest additions into a small marquee set: feature-worthy
    /// types only, must have a backdrop, one slot per title/series, newest first.
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
            // `/Latest` already groups new episodes into their series; drop
            // strays — an episode isn't marquee material.
            guard item.type == .movie || item.type == .series || item.type == .boxSet else { continue }
            guard hasBackdrop(item) else { continue }
            guard seenIds.insert(item.id).inserted else { continue }

            let seriesKey = item.type == .series ? item.id : item.seriesId
            if let seriesKey {
                guard seenSeries.insert(seriesKey).inserted else { continue }
            }
            curated.append(item)
        }
        return curated
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
        guard heroItems.count > 1 else { return }
        pagingDirection = .forward
        pagingGeneration += 1
        heroIndex = (heroIndex + 1) % heroItems.count
        resolveHeroPlayTarget()
    }

    /// Jump to a specific hero item — the paged tab view reports user-driven
    /// page turns (edge navigation, swipes) here. Native paging never wraps,
    /// so plain comparison gives the direction.
    public func selectHero(_ newIndex: Int) {
        guard heroItems.indices.contains(newIndex), newIndex != heroIndex else { return }
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
        guard advanceTask == nil, heroItems.count > 1, pauseReasons.isEmpty else { return }
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

    /// Resolve what Play should start for the current hero item. Movies play
    /// directly; series resolve to their next-up episode (or first episode for
    /// never-started series, per `getNextUpEpisode`); box sets don't play —
    /// their details button is the way in.
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
        case .movie:
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

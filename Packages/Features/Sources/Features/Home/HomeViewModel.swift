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
    /// Global latest fetch feeding hero curation only (the shelves are per-library).
    private static let heroSourceLimit = 16
    private static let latestPerLibraryLimit = 26

    // MARK: - Outputs

    public private(set) var heroItems: [MediaItem] = []
    public private(set) var resumeItems: [MediaItem] = []
    public private(set) var nextUpItems: [MediaItem] = []
    public private(set) var latestShelves: [LibraryShelf] = []

    public private(set) var resumeStatus: SectionStatus = .loading
    public private(set) var nextUpStatus: SectionStatus = .loading
    /// Covers the hero curation source and the per-library rows.
    public private(set) var latestStatus: SectionStatus = .loading

    public private(set) var heroIndex = 0

    /// What the hero Play button should start for the current hero item:
    /// the item itself for movies, the next-up (or first) episode for series,
    /// nil while resolving or for unplayable items (box sets).
    public private(set) var heroPlayTarget: MediaItem?

    /// True until the first load resolves any section.
    public var isInitialLoading: Bool {
        resumeStatus == .loading && nextUpStatus == .loading && latestStatus == .loading
    }

    /// Connected and fully loaded, but the server has nothing to show.
    public var isEmptyServer: Bool {
        resumeStatus == .empty && nextUpStatus == .empty && latestStatus == .empty
    }

    public var currentHeroItem: MediaItem? {
        heroItems.indices.contains(heroIndex) ? heroItems[heroIndex] : nil
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
            heroItems = []
            resumeItems = []
            nextUpItems = []
            latestShelves = []
            resumeStatus = .empty
            nextUpStatus = .empty
            latestStatus = .empty
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
        _ = await (resume, nextUp, latest)

        guard generation == loadGeneration else { return }
        if Task.isCancelled {
            needsLoad = true
            return
        }

        // Hero fallback: when the curation source failed, promote the first
        // backdrop-bearing item so the marquee never goes dark while content
        // exists (single item — no rotation).
        if heroItems.isEmpty {
            let fallback = (resumeItems + nextUpItems).first { client.backdropURL(for: $0) != nil }
            heroItems = fallback.map { [$0] } ?? []
        }
        heroIndex = 0
        resolveHeroPlayTarget()
        startAutoAdvance()

        if resumeStatus.isFailed || nextUpStatus.isFailed || latestStatus.isFailed {
            needsLoad = true
        }
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
        _ = await (resume, nextUp)
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

    private func loadLatest(client: any JellyfinClientProtocol, generation: Int) async {
        async let heroSource = client.getLatestItems(libraryId: nil, limit: Self.heroSourceLimit)

        let capable = libraries.filter { library in
            library.collectionType.map(Self.latestCapable.contains) ?? false
        }
        let shelves = await Self.buildLatestShelves(
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
            latestStatus = (shelves.isEmpty && heroItems.isEmpty) ? .empty : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            latestShelves = shelves
            heroItems = []
            // The per-library rows stand on their own; only report failure
            // when nothing in the section survived.
            latestStatus = shelves.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    /// One "Recently Added" fetch per qualifying library, concurrently, in
    /// library order. Failed or empty libraries simply contribute no row.
    private nonisolated static func buildLatestShelves(
        client: any JellyfinClientProtocol,
        libraries: [Library],
        limit: Int,
    ) async -> [LibraryShelf] {
        let byIndex = await withTaskGroup(of: (Int, LibraryShelf?).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    var items = await (try? client.getLatestItems(libraryId: library.id, limit: limit)) ?? []
                    if library.collectionType == .tvshows {
                        items = await resolvingSeriesEntries(client: client, items: items)
                    }
                    return (index, items.isEmpty ? nil : LibraryShelf(library: library, items: items))
                }
            }
            var results: [Int: LibraryShelf] = [:]
            for await (index, shelf) in group {
                results[index] = shelf
            }
            return results
        }
        return libraries.indices.compactMap { byIndex[$0] }
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

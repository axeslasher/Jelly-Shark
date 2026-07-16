@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("HomeViewModel")
@MainActor
struct HomeViewModelTests {
    private static let movies = Library(id: "movies", name: "Movies", collectionType: .movies)
    private static let shows = Library(id: "shows", name: "Shows", collectionType: .tvshows)
    private static let music = Library(id: "music", name: "Music", collectionType: .music)

    // MARK: - Item factories

    private func movie(_ id: String, backdrop: Bool = true, lastPlayed: Date? = nil) -> MediaItem {
        MediaItem(
            id: id,
            name: id,
            type: .movie,
            imageTags: backdrop ? ImageTags(backdrop: "tag") : nil,
            userData: lastPlayed.map { UserData(lastPlayedDate: $0) },
        )
    }

    private func series(_ id: String, backdrop: Bool = true) -> MediaItem {
        MediaItem(
            id: id,
            name: id,
            type: .series,
            imageTags: backdrop ? ImageTags(backdrop: "tag") : nil,
        )
    }

    private func episode(
        _ id: String,
        seriesId: String,
        lastPlayed: Date? = nil,
        dateAdded: Date? = nil,
    ) -> MediaItem {
        MediaItem(
            id: id,
            name: id,
            type: .episode,
            dateCreated: dateAdded,
            userData: lastPlayed.map { UserData(lastPlayedDate: $0) },
            seriesId: seriesId,
        )
    }

    /// Deterministic engagement dates: day N since the epoch, so later days
    /// are more recent.
    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: Double(offset) * 86400)
    }

    private func boxSet(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .boxSet, imageTags: ImageTags(backdrop: "tag"))
    }

    /// Attach + load in one step, mirroring the view's `.task`.
    private func load(
        _ viewModel: HomeViewModel,
        client: MockJellyfinClient?,
        libraries: [Library] = [],
    ) async {
        viewModel.attach(client: client, libraries: libraries)
        await viewModel.load()
    }

    /// Poll until the condition holds (bounded), resolving async work like
    /// the hero play-target task without a fixed sleep.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Hero curation (pure)

    @Test("Curation keeps only backdrop-bearing movies/series/box sets")
    func curationFiltersTypesAndBackdrops() {
        let latest = [
            movie("m1"),
            episode("e1", seriesId: "s1"),
            movie("m2", backdrop: false),
            series("s2"),
            boxSet("b1"),
        ]
        let curated = HomeViewModel.curateHeroItems(
            from: latest,
            hasBackdrop: { $0.imageTags?.backdrop != nil },
            limit: 10,
        )
        #expect(curated.map(\.id) == ["m1", "s2", "b1"])
    }

    @Test("Curation dedupes ids and collapses repeat series, newest first")
    func curationDedupes() {
        let latest = [
            series("s1"),
            movie("m1"),
            series("s1"), // duplicate id
            movie("m1"), // duplicate id
            movie("m2"),
        ]
        let curated = HomeViewModel.curateHeroItems(
            from: latest,
            hasBackdrop: { _ in true },
            limit: 10,
        )
        #expect(curated.map(\.id) == ["s1", "m1", "m2"])
    }

    @Test("Curation respects the limit")
    func curationLimit() {
        let latest = (0 ..< 8).map { movie("m\($0)") }
        let curated = HomeViewModel.curateHeroItems(
            from: latest,
            hasBackdrop: { _ in true },
            limit: 3,
        )
        #expect(curated.map(\.id) == ["m0", "m1", "m2"])
    }

    // MARK: - Continue Watching merge (pure)

    @Test("Merge interleaves resume and next-up by last engagement, newest first")
    func mergeOrdersByMixedRecency() {
        let merged = HomeViewModel.mergeContinueWatching(
            resume: [movie("m-old", lastPlayed: day(1)), movie("m-new", lastPlayed: day(3))],
            nextUp: [episode("e-newest", seriesId: "s1"), episode("e-older", seriesId: "s2")],
            seriesLastPlayed: ["s1": day(4), "s2": day(2)],
            now: day(10),
        )
        #expect(merged.map(\.id) == ["e-newest", "m-new", "e-older", "m-old"])
    }

    @Test("Dateless items sink to the bottom in source order, resume first")
    func mergeSinksMissingDates() {
        let merged = HomeViewModel.mergeContinueWatching(
            resume: [movie("m-dated", lastPlayed: day(1)), movie("m-dateless")],
            nextUp: [episode("e-unknown", seriesId: "s-unmapped")],
            seriesLastPlayed: [:],
            now: day(10),
        )
        #expect(merged.map(\.id) == ["m-dated", "m-dateless", "e-unknown"])
    }

    @Test("Merge dedupes by id")
    func mergeDedupesById() {
        let merged = HomeViewModel.mergeContinueWatching(
            resume: [episode("e1", seriesId: "s1", lastPlayed: day(2))],
            nextUp: [episode("e1", seriesId: "s1")],
            seriesLastPlayed: ["s1": day(3)],
            now: day(10),
        )
        #expect(merged.map(\.id) == ["e1"])
    }

    @Test("A new episode of an actively watched show outranks a more recent play")
    func mergeBoostsNewEpisodesOfActiveShows() {
        // s1 was watched five days ago but its next episode landed today;
        // s2's next-up file is ancient, so its play date stands. The weekly
        // show beats the movie watched yesterday.
        let merged = HomeViewModel.mergeContinueWatching(
            resume: [movie("m-yesterday", lastPlayed: day(39))],
            nextUp: [
                episode("e-fresh", seriesId: "s1", dateAdded: day(40)),
                episode("e-old-file", seriesId: "s2", dateAdded: day(2)),
            ],
            seriesLastPlayed: ["s1": day(35), "s2": day(36)],
            now: day(40),
        )
        #expect(merged.map(\.id) == ["e-fresh", "m-yesterday", "e-old-file"])
    }

    @Test("A show outside the active window gets no new-episode boost")
    func mergeIgnoresNewEpisodesOfStaleShows() {
        // s1 was abandoned 40 days ago; its new season dropping yesterday is
        // Recently Added's story, not this lane's — it keeps its old play date.
        let merged = HomeViewModel.mergeContinueWatching(
            resume: [movie("m-recent", lastPlayed: day(78))],
            nextUp: [episode("e-new-season", seriesId: "s1", dateAdded: day(79))],
            seriesLastPlayed: ["s1": day(40)],
            now: day(80),
        )
        #expect(merged.map(\.id) == ["m-recent", "e-new-season"])
    }

    @Test("A series played exactly at the window edge still gets the boost")
    func mergeBoostWindowIsInclusive() {
        let merged = HomeViewModel.mergeContinueWatching(
            resume: [movie("m-recent", lastPlayed: day(38))],
            nextUp: [episode("e-fresh", seriesId: "s1", dateAdded: day(39))],
            seriesLastPlayed: ["s1": day(10)], // exactly 30 days before `now`
            now: day(40),
        )
        #expect(merged.map(\.id) == ["e-fresh", "m-recent"])
    }

    @Test("seriesLastPlayedMap keeps each series' most recent play")
    func seriesMapKeepsMostRecent() {
        let map = HomeViewModel.seriesLastPlayedMap(from: [
            episode("e1", seriesId: "s1", lastPlayed: day(1)),
            episode("e2", seriesId: "s1", lastPlayed: day(5)),
            episode("e3", seriesId: "s2", lastPlayed: day(2)),
            episode("e4", seriesId: "s2"), // no date — contributes nothing
            movie("m1", lastPlayed: day(9)), // no series — contributes nothing
        ])
        #expect(map == ["s1": day(5), "s2": day(2)])
    }

    // MARK: - Load statuses

    @Test("A full server loads every section")
    func fullLoad() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("resume-1")])
        client.nextUpItemsResult = .success([episode("next-1", seriesId: "s1")])
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1"), movie("hero-2")])
            case "movies": .success([movie("latest-1")])
            default: .success([])
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])

        #expect(viewModel.resumeStatus == .loaded)
        #expect(viewModel.nextUpStatus == .loaded)
        #expect(viewModel.latestStatus == .loaded)
        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])
        #expect(viewModel.nextUpItems.map(\.id) == ["next-1"])
        #expect(viewModel.latestShelves.map(\.id) == ["movies"])
        #expect(viewModel.heroItems.map(\.id) == ["hero-1", "hero-2"])
        #expect(viewModel.heroIndex == 0)
        #expect(viewModel.isInitialLoading == false)
        #expect(viewModel.isEmptyServer == false)
    }

    @Test("An empty server settles every section at .empty")
    func emptyServer() async {
        let viewModel = HomeViewModel()
        await load(viewModel, client: MockJellyfinClient(), libraries: [Self.movies])

        #expect(viewModel.resumeStatus == .empty)
        #expect(viewModel.nextUpStatus == .empty)
        #expect(viewModel.latestStatus == .empty)
        #expect(viewModel.isEmptyServer)
        #expect(viewModel.heroItems.isEmpty)
    }

    @Test("A nil client parks statuses at .loading — never .empty")
    func nilClientStaysLoading() async {
        // Regression: pre-marking `.empty` here flashed "Nothing here yet"
        // in the beat between the session connecting and the real load.
        let viewModel = HomeViewModel()
        await load(viewModel, client: nil)

        #expect(viewModel.resumeStatus == .loading)
        #expect(viewModel.nextUpStatus == .loading)
        #expect(viewModel.latestStatus == .loading)
        #expect(viewModel.isInitialLoading)
        #expect(viewModel.isEmptyServer == false)
    }

    @Test("First paint waits for every section — a fast shelf can't beat the hero")
    func initialLoadingHoldsUntilAllSectionsSettle() async {
        // Regression: `isInitialLoading` used to clear when ANY section
        // resolved. With resume in first and the hero source still in
        // flight, the content mounted heroless — tvOS focus landed on the
        // Continue Watching row and scrolled the hero away before it showed.
        let client = MockJellyfinClient()
        let gate = AsyncGate()
        client.resumeItemsResult = .success([movie("resume-1")])
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([movie("hero-1")]) : .success([])
        }
        client.latestItemsDelay = { await gate.wait() }

        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [])
        let loadTask = Task { await viewModel.load() }

        await waitUntil { viewModel.resumeStatus == .loaded }
        #expect(viewModel.resumeStatus == .loaded)
        #expect(viewModel.isInitialLoading)

        await gate.open()
        await loadTask.value

        #expect(viewModel.isInitialLoading == false)
        #expect(viewModel.heroItems.map(\.id) == ["hero-1"])
    }

    @Test("One failed section degrades alone and re-arms the next load")
    func sectionFailureRetries() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .failure(APIError.networkError("offline"))
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([movie("hero-1")]) : .success([])
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.resumeStatus.isFailed)
        #expect(viewModel.latestStatus == .loaded)

        // The failure re-armed needsLoad: a plain reload (same client, same
        // libraries — the next appearance) retries and recovers.
        client.resumeItemsResult = .success([movie("resume-1")])
        await viewModel.load()

        #expect(viewModel.resumeStatus == .loaded)
        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])
    }

    @Test("retryFailedSections re-runs only the failed sections, skeleton-free")
    func retryOnlyFailedSections() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .failure(APIError.networkError("offline"))
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1"), movie("hero-2")])
            case "movies": .success([movie("latest-1")])
            default: .success([])
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])
        #expect(viewModel.resumeStatus.isFailed)
        #expect(viewModel.latestStatus == .loaded)

        viewModel.advanceHero()
        let heroIndexBefore = viewModel.heroIndex
        let latestRequestsBefore = client.latestItemsRequests.count

        client.resumeItemsResult = .success([movie("resume-1")])
        await viewModel.retryFailedSections()

        #expect(viewModel.resumeStatus == .loaded)
        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])
        // The loaded sections were untouched: no refetch, no skeleton flip,
        // no marquee yank.
        #expect(client.latestItemsRequests.count == latestRequestsBefore)
        #expect(viewModel.isInitialLoading == false)
        #expect(viewModel.heroIndex == heroIndexBefore)
        #expect(viewModel.heroItems.map(\.id) == ["hero-1", "hero-2"])
    }

    @Test("retryFailedSections recovers a failed Recently Added section's hero")
    func retryFailedLatestSettlesHero() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { _ in .failure(APIError.networkError("offline")) }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])
        #expect(viewModel.latestStatus.isFailed)
        #expect(viewModel.heroItems.isEmpty)

        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1")])
            case "movies": .success([movie("latest-1")])
            default: .success([])
            }
        }
        await viewModel.retryFailedSections()

        #expect(viewModel.latestStatus == .loaded)
        #expect(viewModel.latestShelves.map(\.id) == ["movies"])
        #expect(viewModel.heroItems.map(\.id) == ["hero-1"])
        #expect(viewModel.heroIndex == 0)
    }

    @Test("Loads once per connection; a reappearance is a no-op")
    func loadOncePerConnection() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("resume-1")])

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)
        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])

        client.resumeItemsResult = .success([movie("resume-2")])
        await load(viewModel, client: client)

        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])
    }

    // MARK: - Hero fallback

    @Test("A failed hero source promotes the first backdrop-bearing item")
    func heroFallback() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { libraryId in
            libraryId == nil ? .failure(APIError.networkError("offline")) : .success([])
        }
        client.resumeItemsResult = .success([
            episode("no-backdrop", seriesId: "s1"),
            movie("resume-1"),
        ])

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.heroItems.map(\.id) == ["resume-1"])
        #expect(viewModel.latestStatus.isFailed)
    }

    @Test("Per-library rows stand even when the hero source fails")
    func shelvesSurviveHeroSourceFailure() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .failure(APIError.networkError("offline"))
            case "movies": .success([movie("latest-1")])
            default: .success([])
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])

        #expect(viewModel.latestShelves.map(\.id) == ["movies"])
        #expect(viewModel.latestStatus == .loaded)
    }

    // MARK: - Recently Added shelves

    @Test("One shelf per capable library in order; others contribute none")
    func shelfPerCapableLibrary() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case "movies": .success([movie("m1")])
            case "shows": .success([series("s1")])
            case "music": .success([movie("song")]) // must never be fetched
            default: .success([])
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.music, Self.shows, Self.movies])

        #expect(viewModel.latestShelves.map(\.id) == ["shows", "movies"])
        #expect(!client.latestItemsRequests.contains("music"))
    }

    @Test("TV shelves swap episode entries for their series, collapsed")
    func tvShelvesResolveSeries() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == "shows"
                ? .success([
                    episode("e1", seriesId: "s1"),
                    episode("e2", seriesId: "s1"), // same series — collapses
                    series("s2"),
                ])
                : .success([])
        }
        client.mediaItemsById["s1"] = series("s1")

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.shows])

        let shelf = viewModel.latestShelves.first
        #expect(shelf?.items.map(\.id) == ["s1", "s2"])
        #expect(client.mediaItemRequests == ["s1"])
    }

    @Test("A partial library failure keeps the surviving rows and re-arms")
    func partialLibraryFailureRearms() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1")])
            case "movies": .success([movie("latest-1")])
            default: .failure(APIError.networkError("offline"))
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies, Self.shows])

        // Something survived, so no failure notice — but the gap re-armed a
        // reload for the next appearance.
        #expect(viewModel.latestShelves.map(\.id) == ["movies"])
        #expect(viewModel.latestStatus == .loaded)

        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1")])
            case "movies": .success([movie("latest-1")])
            case "shows": .success([series("latest-2")])
            default: .success([])
            }
        }
        await load(viewModel, client: client, libraries: [Self.movies, Self.shows])

        #expect(viewModel.latestShelves.map(\.id) == ["movies", "shows"])
    }

    @Test("Every library failing reports .failed even when the hero source landed")
    func allLibrariesFailedReportsFailure() async {
        // Regression: shelves.isEmpty used to read as `.empty` whenever the
        // hero curation had items — every row silently vanished with no
        // notice and no re-arm.
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([movie("hero-1")]) : .failure(APIError.networkError("offline"))
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])

        #expect(viewModel.latestStatus.isFailed)
        #expect(viewModel.heroItems.map(\.id) == ["hero-1"])
    }

    @Test("A failed series fetch falls back to the episode entry")
    func tvShelfSeriesFetchFailure() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == "shows" ? .success([episode("e1", seriesId: "s1")]) : .success([])
        }
        client.mediaItemFailureIds = ["s1"]

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.shows])

        #expect(viewModel.latestShelves.first?.items.map(\.id) == ["e1"])
    }

    // MARK: - Hero paging

    private func makePagedViewModel(heroCount: Int) async -> HomeViewModel {
        let client = MockJellyfinClient()
        let heroes = (0 ..< heroCount).map { movie("hero-\($0)") }
        client.latestItemsHandler = { libraryId in
            libraryId == nil ? .success(heroes) : .success([])
        }
        let viewModel = HomeViewModel()
        await load(viewModel, client: client)
        return viewModel
    }

    @Test("advanceHero wraps forward and bumps the generation")
    func advanceWraps() async {
        let viewModel = await makePagedViewModel(heroCount: 3)
        let generation = viewModel.pagingGeneration

        viewModel.advanceHero()
        #expect(viewModel.heroIndex == 1)
        #expect(viewModel.pagingDirection == .forward)
        #expect(viewModel.pagingGeneration == generation + 1)

        viewModel.advanceHero()
        viewModel.advanceHero()
        #expect(viewModel.heroIndex == 0)
        #expect(viewModel.pagingGeneration == generation + 3)
    }

    @Test("advanceHero is a no-op with a single hero item")
    func advanceSingleItem() async {
        let viewModel = await makePagedViewModel(heroCount: 1)
        viewModel.advanceHero()
        #expect(viewModel.heroIndex == 0)
    }

    @Test("selectHero sets direction by comparison and rejects bad indices")
    func selectDirection() async {
        let viewModel = await makePagedViewModel(heroCount: 3)

        viewModel.selectHero(2)
        #expect(viewModel.heroIndex == 2)
        #expect(viewModel.pagingDirection == .forward)

        viewModel.selectHero(1)
        #expect(viewModel.heroIndex == 1)
        #expect(viewModel.pagingDirection == .backward)

        let generation = viewModel.pagingGeneration
        viewModel.selectHero(1) // same index
        viewModel.selectHero(9) // out of range
        #expect(viewModel.heroIndex == 1)
        #expect(viewModel.pagingGeneration == generation)
    }

    // MARK: - Hero play target

    @Test("A movie hero plays itself")
    func moviePlayTarget() async {
        let viewModel = await makePagedViewModel(heroCount: 2)
        #expect(viewModel.heroPlayTarget?.id == "hero-0")
    }

    @Test("A series hero resolves its next-up episode, cached across visits")
    func seriesPlayTarget() async {
        let client = MockJellyfinClient()
        let nextEpisode = episode("s1e4", seriesId: "s1")
        client.nextUpEpisodesBySeries["s1"] = nextEpisode
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([series("s1"), movie("m1")]) : .success([])
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        await waitUntil { viewModel.heroPlayTarget != nil }
        #expect(viewModel.heroPlayTarget?.id == "s1e4")

        // Page away and back: the cached target serves without a refetch.
        viewModel.advanceHero()
        #expect(viewModel.heroPlayTarget?.id == "m1")
        viewModel.advanceHero()
        #expect(viewModel.heroPlayTarget?.id == "s1e4")
        #expect(client.nextUpEpisodeRequests == ["s1"])
    }

    @Test("A box-set hero has no play target")
    func boxSetPlayTarget() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([boxSet("b1"), movie("m1")]) : .success([])
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.heroPlayTarget == nil)
    }

    // MARK: - Auto-advance

    @Test("The timer requests page turns; pausing stops them")
    func autoAdvanceAndPause() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([movie("m1"), movie("m2")]) : .success([])
        }

        let viewModel = HomeViewModel(autoAdvanceInterval: .milliseconds(20))
        await load(viewModel, client: client)

        await waitUntil { viewModel.advanceRequests > 0 }
        #expect(viewModel.advanceRequests > 0)

        viewModel.setPaused(true, reason: .focused)
        let snapshot = viewModel.advanceRequests
        try? await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.advanceRequests == snapshot)

        viewModel.stopAutoAdvance()
    }

    @Test("The timer never starts for a single-item hero")
    func noAutoAdvanceForSingleItem() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([movie("m1")]) : .success([])
        }

        let viewModel = HomeViewModel(autoAdvanceInterval: .milliseconds(20))
        await load(viewModel, client: client)

        try? await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.advanceRequests == 0)
    }

    // MARK: - User-state refresh

    @Test("refreshUserState reloads resume/next-up but never the hero or shelves")
    func refreshUserState() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("resume-1")])
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1")])
            case "movies": .success([movie("latest-1")])
            default: .success([])
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])

        // Playback finished: resume moved on the server; latest didn't.
        client.resumeItemsResult = .success([movie("resume-2")])
        client.latestItemsHandler = { _ in .failure(APIError.networkError("must not refetch")) }
        await viewModel.refreshUserState()

        #expect(viewModel.resumeItems.map(\.id) == ["resume-2"])
        #expect(viewModel.heroItems.map(\.id) == ["hero-1"])
        #expect(viewModel.latestShelves.map(\.id) == ["movies"])
        #expect(viewModel.latestStatus == .loaded)
    }

    // MARK: - Merged Continue Watching lane

    @Test("The merged lane orders a full load by last engagement")
    func mergedLaneFullLoad() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("resume-1", lastPlayed: day(2))])
        client.nextUpItemsResult = .success([episode("next-1", seriesId: "s1")])
        client.recentlyPlayedEpisodesResult = .success([
            episode("watched-1", seriesId: "s1", lastPlayed: day(3)),
        ])

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["next-1", "resume-1"])
        #expect(viewModel.mergedContinueWatchingStatus == .loaded)
        // Split mode reads the same load: the raw outputs stay exactly the
        // server results, untouched by the merge.
        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])
        #expect(viewModel.nextUpItems.map(\.id) == ["next-1"])
    }

    @Test("One empty source leaves the other's items in the lane")
    func mergedLaneOneSourceEmpty() async {
        let client = MockJellyfinClient()
        client.nextUpItemsResult = .success([episode("next-1", seriesId: "s1")])

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["next-1"])
        #expect(viewModel.mergedContinueWatchingStatus == .loaded)
    }

    @Test("Partial results beat an error: one failed source keeps the lane loaded")
    func mergedLanePartialResultsBeatError() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .failure(APIError.networkError("offline"))
        client.nextUpItemsResult = .success([episode("next-1", seriesId: "s1")])

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["next-1"])
        #expect(viewModel.mergedContinueWatchingStatus == .loaded)
        // The raw status still reports the failure, so the needsLoad re-arm
        // and retryFailedSections keep targeting the broken source.
        #expect(viewModel.resumeStatus.isFailed)
    }

    @Test("Both sources failing fails the merged lane")
    func mergedLaneBothFailed() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .failure(APIError.networkError("offline"))
        client.nextUpItemsResult = .failure(APIError.networkError("offline"))

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.mergedContinueWatchingStatus.isFailed)
        #expect(viewModel.mergedContinueWatchingItems.isEmpty)
    }

    @Test("Both sources empty settles the merged lane at .empty")
    func mergedLaneBothEmpty() async {
        let viewModel = HomeViewModel()
        await load(viewModel, client: MockJellyfinClient())
        #expect(viewModel.mergedContinueWatchingStatus == .empty)
    }

    @Test("A failed dates fetch degrades ordering, never the lane")
    func mergedLaneDatesFailureDegradesGracefully() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("resume-1", lastPlayed: day(1))])
        client.nextUpItemsResult = .success([
            episode("next-1", seriesId: "s1"),
            episode("next-2", seriesId: "s2"),
        ])
        client.recentlyPlayedEpisodesResult = .failure(APIError.networkError("offline"))

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        // No sort keys for next-up: dated resume items first, then next-up
        // in server order. Statuses untouched — the dates are enrichment.
        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["resume-1", "next-1", "next-2"])
        #expect(viewModel.mergedContinueWatchingStatus == .loaded)
        #expect(viewModel.isInitialLoading == false)
    }

    @Test("refreshUserState refreshes every merged-lane input")
    func refreshUserStateRefreshesMergedInputs() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .success([movie("resume-1", lastPlayed: day(5))])
        client.nextUpItemsResult = .success([episode("next-1", seriesId: "s1")])
        client.recentlyPlayedEpisodesResult = .success([
            episode("watched-1", seriesId: "s1", lastPlayed: day(1)),
        ])

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)
        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["resume-1", "next-1"])

        // Playback finished: the series is now the freshest engagement. The
        // new order requires the refreshed dates map, proving refreshUserState
        // refetches it alongside resume/next-up.
        client.nextUpItemsResult = .success([episode("next-2", seriesId: "s1")])
        client.recentlyPlayedEpisodesResult = .success([
            episode("next-1", seriesId: "s1", lastPlayed: day(6)),
        ])
        await viewModel.refreshUserState()

        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["next-2", "resume-1"])
    }

    @Test("retryFailedSections refreshes the merged lane's sort keys")
    func retryRefreshesDates() async {
        let client = MockJellyfinClient()
        client.resumeItemsResult = .failure(APIError.networkError("offline"))
        client.nextUpItemsResult = .success([episode("next-1", seriesId: "s1")])
        client.recentlyPlayedEpisodesResult = .failure(APIError.networkError("offline"))

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)
        #expect(viewModel.seriesLastPlayedDates.isEmpty)

        client.resumeItemsResult = .success([movie("resume-1", lastPlayed: day(2))])
        client.recentlyPlayedEpisodesResult = .success([
            episode("watched-1", seriesId: "s1", lastPlayed: day(3)),
        ])
        await viewModel.retryFailedSections()

        #expect(viewModel.mergedContinueWatchingItems.map(\.id) == ["next-1", "resume-1"])
    }
}

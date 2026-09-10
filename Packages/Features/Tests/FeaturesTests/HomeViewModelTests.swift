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

    private func series(
        _ id: String,
        backdrop: Bool = true,
        episodes: Int? = nil,
        unplayed: Int? = nil,
    ) -> MediaItem {
        MediaItem(
            id: id,
            name: id,
            type: .series,
            recursiveItemCount: episodes,
            imageTags: backdrop ? ImageTags(backdrop: "tag") : nil,
            // Deliberately not `unplayed.map { ... }`: the mock runs its
            // handlers off the main actor, and a closure written here inherits
            // this suite's @MainActor isolation — the check traps the moment
            // a non-nil count makes `map` actually call it.
            userData: unplayed == nil ? nil : UserData(unplayedItemCount: unplayed),
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

    /// An episode as `/Latest` returns a lone new arrival: its own primary
    /// still and/or an inherited series backdrop.
    private func heroEpisode(
        _ id: String,
        seriesId: String? = "s1",
        primary: Bool = true,
        seriesBackdrop: Bool = true,
    ) -> MediaItem {
        MediaItem(
            id: id,
            name: "\(id)-name",
            type: .episode,
            imageTags: primary ? ImageTags(primary: "tag") : nil,
            seriesId: seriesId,
            seriesName: "Series",
            indexNumber: 4,
            parentIndexNumber: 2,
            parentArtwork: seriesBackdrop
                ? ParentArtwork(backdropItemId: seriesId ?? "s1", backdropImageTag: "tag")
                : nil,
        )
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
            episode("e1", seriesId: "s1"), // no primary, no series backdrop — not hero material
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

    @Test("Curation admits episodes with hero-capable artwork, one slot per series")
    func curationAdmitsEpisodes() {
        let latest = [
            heroEpisode("e1", seriesId: "s1"),
            heroEpisode("e2", seriesId: "s1"), // same series — collapses
            series("s1"), // the same show as a grouped entry — collapses too
            heroEpisode("e3", seriesId: "s2", primary: false), // series backdrop alone qualifies
            movie("m1"),
        ]
        let curated = HomeViewModel.curateHeroItems(
            from: latest,
            hasBackdrop: { $0.imageTags?.backdrop != nil },
            limit: 10,
        )
        #expect(curated.map(\.id) == ["e1", "e3", "m1"])
    }

    @Test("Curation drops episodes without a series or without any hero artwork")
    func curationDropsUnusableEpisodes() {
        let latest = [
            heroEpisode("e-stray", seriesId: nil),
            heroEpisode("e-bare", seriesId: "s1", primary: false, seriesBackdrop: false),
            movie("m1"),
        ]
        let curated = HomeViewModel.curateHeroItems(
            from: latest,
            hasBackdrop: { _ in true },
            limit: 10,
        )
        #expect(curated.map(\.id) == ["m1"])
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

    // MARK: - Hero media-sources second pass

    @Test("Curated heroes get sources from the ids batch, keeping /Latest's grouped shape")
    func heroSourcesSecondPass() async {
        let client = MockJellyfinClient()
        // A grouped-series entry as /Latest returns it: childCount is the
        // group's size (the "N New Episodes" label), not the season count.
        let grouped = MediaItem(
            id: "s1", name: "s1", type: .series,
            childCount: 80, imageTags: ImageTags(backdrop: "tag"),
        )
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([grouped, movie("m1")]) : .success([])
        }
        client.mediaItemsHandler = { _ in .success([
            // The plainly-fetched series: real season count, sources — only
            // the sources may survive the merge.
            MediaItem(id: "s1", name: "s1", type: .series, childCount: 4,
                      mediaSources: [MediaSource(id: "s1-src")]),
            MediaItem(id: "m1", name: "m1", type: .movie,
                      mediaSources: [MediaSource(id: "m1-src-1"), MediaSource(id: "m1-src-2")]),
        ]) }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(client.mediaItemsRequests == [["s1", "m1"]])
        #expect(viewModel.heroItems.map { $0.mediaSources?.count } == [1, 2])
        #expect(viewModel.heroItems.first?.childCount == 80)
    }

    @Test("A failed sources batch leaves the heroes sourceless, not the section failed")
    func heroSourcesSecondPassFailure() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == nil ? .success([movie("m1"), movie("m2")]) : .success([])
        }
        client.mediaItemsHandler = { _ in .failure(APIError.networkError("offline")) }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.latestStatus == .loaded)
        #expect(viewModel.heroItems.map(\.id) == ["m1", "m2"])
        #expect(viewModel.heroItems.allSatisfy { $0.mediaSources == nil })
    }

    @Test("An empty hero set skips the sources batch")
    func heroSourcesSecondPassSkippedWhenEmpty() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { _ in .success([]) }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        #expect(client.mediaItemsRequests.isEmpty)
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

    @Test("A nil-client load reports .superseded, not the enum's default")
    func nilClientReportsSuperseded() async {
        // `completeInitialLoad(succeeded:)` reads this. Leaving it stale
        // reported success for a load that fetched nothing, which stamped
        // the refresh floor and suppressed the external-client fallback.
        let viewModel = HomeViewModel()
        await load(viewModel, client: nil)

        #expect(viewModel.lastLoadOutcome == .superseded)
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
        client.latestItemsDelay = { try? await gate.wait() }

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

    // MARK: - Warm reload lifecycle (#236 § 3)

    @Test func aWarmReloadNeverReturnsToTheSkeleton() async {
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        #expect(viewModel.isInitialLoading == false)

        let gate = AsyncGate()
        client.resumeItemsDelay = { try? await gate.wait() }
        viewModel.forceReload()
        let second = Task { await viewModel.load() }
        try? await Task.sleep(for: .milliseconds(20))
        // Content is rendered; a reload must reconcile in place. Parking at
        // `.loading` here is what put the skeleton back over a warm page.
        #expect(viewModel.isInitialLoading == false)
        await gate.open()
        await second.value
    }

    @Test func anEmptyServerStaysEmptyAcrossAReloadRatherThanFlashingTheSkeleton() async {
        // Emptiness is content state, not lifecycle state: this Home has
        // completed a load and has nothing to show, which is not the same as
        // "still finding out".
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        #expect(viewModel.isEmptyServer)

        let gate = AsyncGate()
        client.resumeItemsDelay = { try? await gate.wait() }
        viewModel.forceReload()
        let second = Task { await viewModel.load() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.isInitialLoading == false)
        await gate.open()
        await second.value
    }

    @Test func aColdLoadStillShowsTheSkeletonExactlyOnce() async {
        let clientA = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: clientA, libraries: [Self.movies])
        await viewModel.load()
        #expect(viewModel.isInitialLoading == false)

        // A genuinely new connection re-arms the skeleton (#236 § 3):
        // `attach` resets `hasCompletedInitialLoad` only on a changed
        // client, so this second cold load — unlike a warm reload of the
        // same client above — must show the skeleton again exactly once.
        let clientB = MockJellyfinClient()
        let gate = AsyncGate()
        clientB.resumeItemsDelay = { try? await gate.wait() }
        viewModel.attach(client: clientB, libraries: [Self.movies])
        let second = Task { await viewModel.load() }
        await waitUntil { viewModel.isInitialLoading }
        #expect(viewModel.isInitialLoading)
        await gate.open()
        await second.value
        #expect(viewModel.isInitialLoading == false)
    }

    @Test func aLibraryListChangeDoesNotBringBackTheSkeleton() async {
        // Acceptance criterion 5: adding/removing a library is a warm
        // reload, not a new session — `attach` only re-arms the skeleton on
        // a changed client (see the test above), never on a library-list
        // change alone.
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        #expect(viewModel.isInitialLoading == false)

        let gate = AsyncGate()
        client.resumeItemsDelay = { try? await gate.wait() }
        let latestRequestsBefore = client.latestItemsRequests.count
        viewModel.attach(client: client, libraries: [Self.movies, Self.shows])
        let second = Task { await viewModel.load() }
        // Resume itself is gated, so wait on the ungated latest fetch firing
        // instead — proof the load is genuinely in flight, not merely
        // scheduled.
        await waitUntil { client.latestItemsRequests.count > latestRequestsBefore }
        #expect(viewModel.isInitialLoading == false)
        await gate.open()
        await second.value
    }

    @Test func loadReportsWhetherItActuallyRan() async {
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        #expect(await viewModel.load())
        // Guarded out: the caller must be able to tell, or it will stamp the
        // refresh floor for a load that never happened.
        #expect(await viewModel.load() == false)
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

    @Test func aPartialRecentlyAddedFailureIsReportedAsFailure() async {
        // `loadLatest` keeps `.loaded` when some shelves survived, so the
        // status says "fine" while one library's row is stale.
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case nil: .success([movie("hero-1")])
            case "movies": .success([movie("latest-1")])
            default: .failure(APIError.networkError("offline"))
            }
        }
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies, Self.shows])
        await viewModel.load()
        #expect(viewModel.latestStatus == .loaded)
        #expect(viewModel.lastLoadOutcome == .failed)
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

    // MARK: - Episode heroes

    /// Load a Home whose hero source returns just the given episode.
    private func loadEpisodeHero(
        _ episode: MediaItem,
        imageInfos: [ItemImageInfo]? = nil,
        infoFails: Bool = false,
    ) async -> (viewModel: HomeViewModel, client: MockJellyfinClient) {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { libraryId in
            libraryId == nil ? .success([episode]) : .success([])
        }
        if let imageInfos {
            client.imageInfosById[episode.id] = imageInfos
        }
        if infoFails {
            client.imageInfoFailureIds = [episode.id]
        }
        let viewModel = HomeViewModel()
        await load(viewModel, client: client)
        return (viewModel, client)
    }

    @Test("An episode hero with a wide-enough primary rides its own still")
    func episodeHeroUsesWidePrimary() async {
        // Exactly the floor width: the rule is inclusive (≥ 1080).
        let (viewModel, _) = await loadEpisodeHero(
            heroEpisode("e1"),
            imageInfos: [ItemImageInfo(imageType: .primary, width: 1080, height: 608)],
        )
        #expect(viewModel.heroItems.map(\.id) == ["e1"])
        let url = viewModel.heroBackdropURL(for: viewModel.heroItems[0])
        #expect(url?.path() == "/Items/e1/Images/Primary")
    }

    @Test("A narrow primary falls back to the series backdrop")
    func episodeHeroNarrowPrimaryFallsBack() async {
        let (viewModel, _) = await loadEpisodeHero(
            heroEpisode("e1", seriesId: "s1"),
            imageInfos: [ItemImageInfo(imageType: .primary, width: 720, height: 405)],
        )
        #expect(viewModel.heroItems.map(\.id) == ["e1"])
        let url = viewModel.heroBackdropURL(for: viewModel.heroItems[0])
        #expect(url?.path() == "/Items/s1/Images/Backdrop")
    }

    @Test("A failed image-info lookup degrades to the series backdrop")
    func episodeHeroInfoFailureFallsBack() async {
        let (viewModel, _) = await loadEpisodeHero(heroEpisode("e1", seriesId: "s1"), infoFails: true)
        #expect(viewModel.heroItems.map(\.id) == ["e1"])
        let url = viewModel.heroBackdropURL(for: viewModel.heroItems[0])
        #expect(url?.path() == "/Items/s1/Images/Backdrop")
    }

    @Test("A narrow primary with no series backdrop drops the episode from the hero")
    func episodeHeroWithNoUsableImageIsDropped() async {
        let (viewModel, _) = await loadEpisodeHero(
            heroEpisode("e1", seriesBackdrop: false),
            imageInfos: [ItemImageInfo(imageType: .primary, width: 720, height: 405)],
        )
        #expect(viewModel.heroItems.isEmpty)
    }

    @Test("An episode hero plays itself — no next-up resolution")
    func episodeHeroPlaysItself() async {
        let (viewModel, client) = await loadEpisodeHero(
            heroEpisode("e1"),
            imageInfos: [ItemImageInfo(imageType: .primary, width: 1920, height: 1080)],
        )
        #expect(viewModel.heroPlayTarget?.id == "e1")
        #expect(client.nextUpEpisodeRequests.isEmpty)
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
        // Safe fixed sleep: this asserts nothing happens, so a loaded machine can
        // only make it more true. Polling cannot prove a negative.
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

        // Safe fixed sleep: asserts the timer never fires — a negative that
        // polling cannot establish, and that load only reinforces.
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

    @Test("refreshUserState re-reads the unwatched counts on Recently Added series")
    func refreshUserStateUpdatesContainerCounts() async {
        let tv = Library(id: "tv", name: "TV", collectionType: .tvshows)
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            switch libraryId {
            case "tv": .success([series("show-1", episodes: 10, unplayed: 6)])
            default: .success([])
            }
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [tv])
        #expect(viewModel.latestShelves.first?.items.first?.cardProgress == 0.4)

        // An episode was watched during playback: the series now has one
        // fewer unwatched. Recently Added itself must not refetch.
        client.latestItemsHandler = { _ in .failure(APIError.networkError("must not refetch")) }
        // Built here, not inside the handler: the mock calls handlers off the
        // main actor, and this suite is @MainActor.
        let refreshed = [series("show-1", episodes: 10, unplayed: 5)]
        client.mediaItemsHandler = { _ in .success(refreshed) }
        await viewModel.refreshUserState()

        let card = viewModel.latestShelves.first?.items.first
        #expect(card?.userData?.unplayedItemCount == 5)
        #expect(card?.cardProgress == 0.5)
        // The count came from an ids= fetch, and the immutable episode total
        // survived it.
        #expect(client.mediaItemsRequests == [["show-1"]])
        #expect(card?.recursiveItemCount == 10)
    }

    @Test("refreshUserState asks for no counts when no series are on screen")
    func refreshUserStateSkipsCountsWithoutSeries() async {
        let client = MockJellyfinClient()
        client.latestItemsHandler = { [self] libraryId in
            libraryId == "movies" ? .success([movie("latest-1")]) : .success([])
        }

        let viewModel = HomeViewModel()
        await load(viewModel, client: client, libraries: [Self.movies])
        let before = client.mediaItemsRequests.count
        await viewModel.refreshUserState()

        #expect(client.mediaItemsRequests.count == before)
    }

    @Test func refreshUserStateReportsFailureEvenWhenTheLaneKeepsItsContent() async {
        let client = MockJellyfinClient()
        // Built here, not inside the handler: `resumeItemsHandler` is
        // `@Sendable` and runs off the main actor, but `movie(_:)` inherits
        // this suite's @MainActor isolation.
        let resumeItem = movie("resume-1")
        client.resumeItemsHandler = { _ in .success([resumeItem]) }
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        struct Boom: Error {}
        client.resumeItemsHandler = { _ in .failure(Boom()) }

        // The lane deliberately keeps `.loaded` so a rendered row is not
        // blanked over a refresh failure — so status cannot be the signal.
        #expect(await viewModel.refreshUserState() == .failed)
        #expect(viewModel.resumeStatus == .loaded)
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

    // MARK: - Cancellation is not failure (#236 § 8.4)

    @Test func aCancelledResumeLoadLeavesNoFailureNotice() async {
        let client = MockJellyfinClient()
        client.resumeItemsHandler = { _ in .failure(CancellationError()) }
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        // A cancelled request is a cancellation, never "Couldn't load".
        #expect(viewModel.resumeStatus.isFailed == false)
    }

    @Test func theDrainOutcomeMappingTreatsSupersessionAsCancellation() {
        #expect(HomeViewModel.LoadOutcome.succeeded.drainOutcome == .succeeded)
        #expect(HomeViewModel.LoadOutcome.failed.drainOutcome == .failed)
        // The whole cancellation story rests on this row: a superseded pass
        // confirmed nothing, so the reason is still owed. Mapping it to
        // `.failed` would leave it owed but never wake a drain for it, and
        // `.succeeded` would stamp the floor for work that never happened.
        #expect(HomeViewModel.LoadOutcome.superseded.drainOutcome == .cancelled)
    }

    @Test func aCancelledRefreshIsSupersededNotFailed() async {
        let client = MockJellyfinClient()
        client.resumeItemsHandler = { _ in .failure(CancellationError()) }
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        // Neither outcome the drain acts on: a cancelled refresh must not
        // start the floor, and re-posting for it would spin.
        #expect(await viewModel.refreshUserState() == .superseded)
    }

    @Test("Task cancellation leaves no failure in any lane")
    func taskCancellationLeavesNoFailure() async {
        // Real clients emit APIError.networkError(URLError(.cancelled).localizedDescription),
        // not CancellationError. This test verifies the fix works against that shape.
        let realCancellationError = APIError.networkError(URLError(.cancelled).localizedDescription)

        let client = MockJellyfinClient()
        let gate = AsyncGate()

        // Hold all three section loaders at their delay point until after task cancel.
        client.resumeItemsResult = .failure(realCancellationError)
        client.nextUpItemsResult = .failure(realCancellationError)
        client.latestItemsHandler = { _ in .failure(realCancellationError) }
        client.resumeItemsDelay = { try? await gate.wait() }
        client.nextUpItemsDelay = { try? await gate.wait() }
        client.latestItemsDelay = { try? await gate.wait() }

        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])

        // Load in a task so we can cancel it mid-flight.
        let task = Task {
            await viewModel.load()
        }

        // Let loaders reach the gate, then cancel the task.
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()

        // Release the gate: the requests that resumed will throw the
        // cancellation-shaped error after the task saw isCancelled.
        await gate.open()
        await task.value

        // No lane paints failure despite the error shape matching a network
        // error: Task.isCancelled short-circuits the failure path.
        #expect(viewModel.resumeStatus.isFailed == false)
        #expect(viewModel.nextUpStatus.isFailed == false)
        #expect(viewModel.latestStatus.isFailed == false)
    }

    // MARK: - User-data actions (shelf card menus)

    @Test("setPlayed persists and flips the card in place")
    func setPlayedFlipsTheCard() async {
        let client = MockJellyfinClient()
        let item = movie("resume-1", lastPlayed: day(1))
        client.resumeItemsResult = .success([item])
        let viewModel = HomeViewModel()
        await load(viewModel, client: client)
        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])

        await viewModel.setPlayed(true, for: item)

        #expect(client.userDataCalls.map(\.action) == ["played"])
        #expect(client.userDataCalls.map(\.itemId) == ["resume-1"])
        // Lane membership — the watched item leaving Continue Watching —
        // is the drain's job now, not a second fan-out from here (#236).
        #expect(viewModel.resumeItems[0].userData?.played == true)
    }

    @Test func aSupersededLibraryRefreshReportsSupersededNotTheWinnersOutcome() async {
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()

        let gate = AsyncGate()
        client.resumeItemsDelay = { try? await gate.wait() }
        let first = Task { await viewModel.refresh(.libraries) }
        try? await Task.sleep(for: .milliseconds(20))
        // A Retry during the warm refresh starts a newer generation.
        viewModel.forceReload()
        let second = Task { await viewModel.load() }
        try? await Task.sleep(for: .milliseconds(20))
        await gate.open()
        _ = await second.value

        // The drain must put `.libraries` back, not retire it on the strength
        // of a pass that never rebuilt Recently Added.
        #expect(await first.value == .superseded)
    }

    @Test func setPlayedDoesNotRefreshOnItsOwn() async {
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        let afterLoad = client.resumeItemsRequests.count

        await viewModel.setPlayed(true, for: movie("m-1"))

        // The confirmed toggle bumps `mutationRevision`, RootView posts
        // `.watchState`, and the drain refreshes once. Refreshing here too
        // would fan out twice for one toggle.
        #expect(client.resumeItemsRequests.count == afterLoad)
    }

    // MARK: - Tiered refresh (#236 § 5.1)

    @Test func aLibrariesRefreshReloadsRecentlyAddedAndAWatchStateOneDoesNot() async {
        let client = MockJellyfinClient()
        let viewModel = HomeViewModel()
        viewModel.attach(client: client, libraries: [Self.movies])
        await viewModel.load()
        let afterLoad = client.latestItemsRequests.count

        // The shallow tier must not rebuild the hero's source — a silent
        // re-check that restarts the marquee reads as a bug.
        _ = await viewModel.refresh(.watchState)
        #expect(client.latestItemsRequests.count == afterLoad)

        _ = await viewModel.refresh(.libraries)
        #expect(client.latestItemsRequests.count > afterLoad)
    }

    @Test("setPlayed reverts the optimistic flip when the server call fails")
    func setPlayedRevertsOnFailure() async {
        let client = MockJellyfinClient()
        let item = movie("resume-1", lastPlayed: day(1))
        client.resumeItemsResult = .success([item])
        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        client.userDataError = APIError.networkError("offline")
        await viewModel.setPlayed(true, for: item)

        #expect(viewModel.resumeItems.map(\.id) == ["resume-1"])
        #expect(viewModel.resumeItems[0].userData?.played != true)
    }

    @Test("setFavorite flips the card in place without touching the lanes")
    func setFavoriteFlipsInPlace() async {
        let client = MockJellyfinClient()
        let item = movie("resume-1", lastPlayed: day(1))
        client.resumeItemsResult = .success([item])
        let viewModel = HomeViewModel()
        await load(viewModel, client: client)

        // Poison the lane fetches: a favorite change must not refetch them.
        client.resumeItemsResult = .failure(APIError.networkError("no refresh expected"))
        await viewModel.setFavorite(true, for: item)

        #expect(client.userDataCalls.map(\.action) == ["favorite"])
        #expect(viewModel.resumeItems[0].userData?.isFavorite == true)

        client.userDataError = APIError.networkError("offline")
        await viewModel.setFavorite(false, for: viewModel.resumeItems[0])
        #expect(viewModel.resumeItems[0].userData?.isFavorite == true)
    }
}

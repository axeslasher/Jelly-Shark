@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("AffinityShelvesViewModel")
@MainActor
struct AffinityShelvesViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    private let moviesLibrary = Library(id: "lib-movies", name: "Films", collectionType: .movies)

    /// Distinct counts and a real shelf page. Without these, `librarySize`
    /// and the Horror count are the same number — a ratio of 1.0, which
    /// qualifies nothing — and every shelf comes back empty, so the
    /// lifecycle tests below would assert against zero rows and prove
    /// nothing.
    private func configured() -> MockJellyfinClient {
        let mock = MockJellyfinClient()
        mock.affinityMoviesResult = (0 ..< 5).map { movie("m\($0)") }
        mock.affinityLibrarySizeResult = 1000
        mock.affinityBucketCountResult = 20
        // `libraryItemsHandler`, not `libraryItemsPages`: affinity can make
        // up to three shelf fetches and the array form is consumed per call.
        mock.libraryItemsHandler = { _ in
            .success(MediaItemPage(
                items: (0 ..< 10).map { MediaItem(id: "shelf\($0)", name: "Shelf \($0)", type: .movie) },
                startIndex: 0,
                totalRecordCount: 10,
            ))
        }
        mock.similarItemsResult = .success(
            (0 ..< 10).map { MediaItem(id: "sim\($0)", name: "Sim \($0)", type: .movie) },
        )
        return mock
    }

    private func movie(_ id: String, genres: [String] = ["Horror"]) -> MediaItem {
        MediaItem(
            id: id, name: "Movie \(id)", type: .movie, productionYear: 1987, genres: genres,
            userData: UserData(lastPlayedDate: Date(timeIntervalSince1970: 1_767_225_600)),
        )
    }

    private func episode(_ id: String, seriesId: String) -> MediaItem {
        MediaItem(
            id: id, name: "E\(id)", type: .episode,
            userData: UserData(lastPlayedDate: Date(timeIntervalSince1970: 1_767_225_600)),
            seriesId: seriesId,
        )
    }

    /// Spec § 13 case 34 — the fetch/normalization boundary. The pure engine
    /// cannot catch this: a shared window would be truncated server-side
    /// before the collapse ran.
    @Test func aBingeDoesNotCrowdFilmsOutOfTheSignalSet() async {
        let mock = MockJellyfinClient()
        mock.affinityEpisodesResult = (0 ..< 60).map { episode("e\($0)", seriesId: "s1") }
        mock.affinityItemsResult = [MediaItem(id: "s1", name: "Series", type: .series, genres: ["Drama"])]
        mock.affinityMoviesResult = (0 ..< 40).map { movie("m\($0)") }

        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        #expect(model.lastSignalCount == 41)
    }

    @Test func theTwoPlayWindowsUseTheirOwnLimits() async {
        let mock = MockJellyfinClient()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        #expect(mock.affinityMovieLimits == [AffinityTuning.playedMovieLimit])
        #expect(mock.affinityEpisodeLimits == [AffinityTuning.playedEpisodeLimit])
    }

    @Test func seriesHydrationIsSkippedWhenNoEpisodesWerePlayed() async {
        let mock = MockJellyfinClient()
        mock.affinityMoviesResult = [movie("m1")]
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        #expect(mock.affinityItemsRequests.isEmpty)
    }

    @Test func onlyBucketsClearingTheFloorAreProbed() async {
        let mock = MockJellyfinClient()
        // Five Horror films clear the floor; one Comedy film does not.
        mock.affinityMoviesResult = (0 ..< 5).map { movie("m\($0)") } + [movie("c1", genres: ["Comedy"])]
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        let probedGenres = mock.affinityCountRequests.flatMap { Array($0.genres) }
        #expect(probedGenres.contains("Horror"))
        #expect(!probedGenres.contains("Comedy"))
    }

    @Test func anEmptyHistoryProducesNoShelvesAndNoProbesBeyondLibrarySize() async {
        let mock = MockJellyfinClient()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        #expect(model.shelves.isEmpty)
        #expect(model.status == .empty)
        // Only the unfiltered librarySize probe.
        #expect(mock.affinityCountRequests.count == 1)
        #expect(mock.affinityCountRequests[0].genres.isEmpty)
        #expect(mock.affinityCountRequests[0].personID == nil)
    }

    @Test func disabledMeansNoFetchesAtAll() async {
        let mock = MockJellyfinClient()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.setEnabled(false)
        await model.validate(now: now)

        #expect(mock.affinityMovieLimits.isEmpty)
        #expect(mock.affinityCountRequests.isEmpty)
        #expect(model.shelves.isEmpty)
    }

    @Test func turningItOffDiscardsRowsButKeepsThemForTurningItBackOn() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let built = model.shelves.count
        #expect(built > 0)

        await model.setEnabled(false)
        #expect(model.shelves.isEmpty)

        await model.setEnabled(true)
        #expect(model.shelves.count == built)
    }

    /// Revision 7: a fingerprint validated this session, with nothing having
    /// asked for a refresh since, means the rows are known-current.
    @Test func aCleanToggleBackOnTouchesTheNetworkNotAtAll() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        #expect(!model.shelves.isEmpty)

        await model.setEnabled(false)
        let before = mock.affinityMovieLimits.count
        await model.setEnabled(true)

        #expect(mock.affinityMovieLimits.count == before)
    }

    /// A `.libraries` drain while off must come back as a reload, not a
    /// downgraded validate that reuses the stamp inside its TTL.
    @Test func aLibraryRefreshWhileDisabledComesBackAsAReload() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let probesBefore = mock.affinityCountRequests.filter { $0.genres.isEmpty && $0.personID == nil }.count

        await model.setEnabled(false)
        await model.reload(now: now.addingTimeInterval(60))
        await model.setEnabled(true)

        // Inside `stampTTL`, so only a forced probe can have happened.
        #expect(mock.affinityCountRequests.filter { $0.genres.isEmpty && $0.personID == nil }.count > probesBefore)
        #expect(model.recomputeCount == 2)
    }

    /// A `.libraries` refresh interrupted by the toggle must not come back
    /// as a `.validate`.
    @Test func disablingDuringAReloadPutsThatReloadBackOnTheBooks() async {
        let mock = configured()
        let gate = AsyncGate()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        #expect(model.recomputeCount == 1)

        mock.affinityGate = gate
        let running = Task { await model.reload(now: now) }
        for _ in 0 ..< 100 where mock.affinityMovieLimits.count < 2 {
            await Task.yield()
        }

        await model.setEnabled(false)
        await running.value
        await gate.open()
        mock.affinityGate = nil

        await model.setEnabled(true)
        // The interrupted reload ran, rather than being skipped as
        // known-current or downgraded to a validate.
        #expect(model.recomputeCount == 2)
    }

    /// One person's recommendations must never render for another, and must
    /// go the moment the scope changes rather than when a replacement lands.
    @Test func switchingProfileDropsThePreviousProfilesRowsImmediately() async {
        let mock = configured()

        func scoped(_ userID: String) -> ScopedCache {
            ScopedCache(store: MediaCacheStore.makeInMemory(), scope: .init(
                serverURL: URL(string: "https://example.com")!, userID: userID,
            ))
        }

        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: scoped("u1"))
        await model.validate(now: now)
        #expect(!model.shelves.isEmpty)

        // Same client, same libraries, empty cache for the new profile.
        model.attach(client: mock, libraries: [moviesLibrary], cache: scoped("u2"))
        #expect(model.shelves.isEmpty)
        #expect(model.status == .loading)

        // And nothing comes back from the new profile's empty cache.
        await model.hydrate()
        #expect(model.shelves.isEmpty)
    }

    @Test func aSameProfileLibraryChangeKeepsTheRowsOnScreen() async {
        let mock = configured()
        let cache = ScopedCache(store: MediaCacheStore.makeInMemory(), scope: .init(
            serverURL: URL(string: "https://example.com")!, userID: "u1",
        ))
        let tvLibrary = Library(id: "lib-tv", name: "Shows", collectionType: .tvshows)

        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: cache)
        await model.validate(now: now)
        let built = model.shelves
        #expect(!built.isEmpty)

        // Still this viewer — blanking Home to re-derive the same shelves is
        // focus churn nobody asked for.
        model.attach(client: mock, libraries: [moviesLibrary, tvLibrary], cache: cache)
        #expect(model.shelves == built)
    }

    /// A profile switch on the same server: same client, same libraries,
    /// different scope.
    @Test func attachingADifferentScopeSupersedesTheInFlightPass() async {
        let mock = configured()
        let gate = AsyncGate()
        mock.affinityGate = gate

        func scoped(_ userID: String) -> ScopedCache {
            ScopedCache(store: MediaCacheStore.makeInMemory(), scope: .init(
                serverURL: URL(string: "https://example.com")!, userID: userID,
            ))
        }

        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: scoped("u1"))
        let running = Task { await model.validate(now: now) }
        for _ in 0 ..< 100 where mock.affinityMovieLimits.isEmpty {
            await Task.yield()
        }

        model.attach(client: mock, libraries: [moviesLibrary], cache: scoped("u2"))
        await gate.open()
        await running.value

        #expect(model.shelves.isEmpty)
        #expect(model.recomputeCount == 0)
    }

    /// An old pass must not combine a stale client's response with a newly
    /// attached library set or cache.
    @Test func attachingADifferentServerSupersedesTheInFlightPass() async {
        let first = configured()
        let gate = AsyncGate()
        first.affinityGate = gate
        let second = configured()

        let model = AffinityShelvesViewModel()
        model.attach(client: first, libraries: [moviesLibrary], cache: nil)
        let running = Task { await model.validate(now: now) }
        for _ in 0 ..< 100 where first.affinityMovieLimits.isEmpty {
            await Task.yield()
        }

        model.attach(client: second, libraries: [moviesLibrary], cache: nil)
        await gate.open()
        await running.value

        // The superseded pass published nothing.
        #expect(model.shelves.isEmpty)
        #expect(model.recomputeCount == 0)
    }

    /// A failure proves nothing about freshness.
    @Test func aFailedPassIsNotTreatedAsFreshOnTheNextToggle() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        mock.affinityFailure = MockError.boom
        await model.validate(now: now.addingTimeInterval(86400))
        #expect(model.status.isFailed)

        mock.affinityFailure = nil
        await model.setEnabled(false)
        let before = mock.affinityMovieLimits.count
        await model.setEnabled(true)

        // Not skipped as known-current: the failure put the work back on
        // the books.
        #expect(mock.affinityMovieLimits.count > before)
    }

    /// No toggle involved: a plain validate after a failed reload must still
    /// run at reload strength, or it matches the old fingerprint, skips the
    /// rebuild, and wipes a debt it never paid.
    @Test func aValidateAfterAFailedReloadRunsAtReloadStrength() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        #expect(model.recomputeCount == 1)

        mock.affinityFailure = MockError.boom
        await model.reload(now: now)
        mock.affinityFailure = nil

        await model.validate(now: now)
        #expect(model.recomputeCount == 2)
    }

    /// A validate that supersedes an in-flight reload inherits its strength.
    @Test func aValidateSupersedingAnActiveReloadInheritsItsStrength() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        #expect(model.recomputeCount == 1)

        let gate = AsyncGate()
        mock.affinityGate = gate
        let reloading = Task { await model.reload(now: now) }
        for _ in 0 ..< 100 where mock.affinityMovieLimits.count < 2 {
            await Task.yield()
        }

        mock.affinityGate = nil
        await model.validate(now: now)
        await gate.open()
        await reloading.value

        // The superseding validate did the reload's work rather than
        // matching the fingerprint and returning early.
        #expect(model.recomputeCount == 2)
    }

    @Test func aFailedReloadComesBackAsAReloadNotAValidate() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        mock.affinityFailure = MockError.boom
        await model.reload(now: now)
        mock.affinityFailure = nil

        await model.setEnabled(false)
        await model.setEnabled(true)
        // A downgraded validate would have matched the fingerprint and
        // skipped the rebuild.
        #expect(model.recomputeCount == 2)
    }

    @Test func theStrongestRefreshWhileDisabledWins() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        await model.setEnabled(false)
        await model.validate(now: now)
        await model.reload(now: now)
        await model.validate(now: now)
        await model.setEnabled(true)

        // The reload's strength survives the two validates around it.
        #expect(model.recomputeCount == 2)
    }

    /// Cancelling the caller must cancel the owned pass, or Home's
    /// revision-keyed drain leaves a pass running and hangs on it.
    @Test func cancellingTheCallerCancelsThePass() async {
        let mock = configured()
        let gate = AsyncGate()
        mock.affinityGate = gate

        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        let caller = Task { await model.validate(now: now) }
        for _ in 0 ..< 100 where mock.affinityMovieLimits.isEmpty {
            await Task.yield()
        }

        caller.cancel()
        await caller.value
        await gate.open()

        #expect(mock.affinityCountRequests.isEmpty)
    }

    /// An empty model that failed once must not show Retry forever.
    @Test func aSuccessfulUnchangedPassClearsAPreviousFailure() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        mock.affinityFailure = MockError.boom
        await model.validate(now: now.addingTimeInterval(86400))
        #expect(model.status.isFailed)

        mock.affinityFailure = nil
        await model.validate(now: now)
        #expect(!model.status.isFailed)
    }

    /// The next launch must not repeat a size probe this session just did.
    @Test func anUnchangedPassPersistsItsRefreshedProbeTimestamp() async {
        let mock = configured()
        let cache = ScopedCache(store: MediaCacheStore.makeInMemory(), scope: .init(
            serverURL: URL(string: "https://example.com")!, userID: "u1",
        ))
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: cache)
        await model.validate(now: now)
        let rows = model.shelves

        // Past `stampTTL`, so the next pass re-probes; the fingerprint still
        // matches because the day and the counts are unchanged.
        let later = now.addingTimeInterval(AffinityTuning.stampTTL + 60)
        await model.validate(now: later)

        let persisted = await cache.read(CachedAffinityShelves.self, key: .affinityShelves)
        #expect(persisted?.stampProbedAt == later)
        #expect(persisted?.shelves == rows)
    }

    @Test func aRefreshArrivingWhileDisabledForcesAPassWhenTurnedBackOn() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        await model.setEnabled(false)
        // A drain fired while switched off. It issues nothing, but it does
        // mean the validated fingerprint no longer proves anything.
        await model.validate(now: now)
        let before = mock.affinityMovieLimits.count

        await model.setEnabled(true)
        #expect(mock.affinityMovieLimits.count > before)
    }

    /// The library branch must rebuild even when the id set and item count
    /// happen to be unchanged — otherwise the fingerprint matches and the
    /// rebuild is skipped on the one path that knows the library moved.
    @Test func reloadRecomputesEvenWhenTheFingerprintIsUnchanged() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        #expect(model.recomputeCount == 1)

        await model.validate(now: now)
        #expect(model.recomputeCount == 1)

        await model.reload(now: now)
        #expect(model.recomputeCount == 2)
    }

    @Test func aFailedPassKeepsThePreviousRowsAndReportsFailed() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let built = model.shelves
        #expect(!built.isEmpty)

        mock.affinityFailure = MockError.boom
        await model.retry(now: now.addingTimeInterval(7200))

        #expect(model.shelves == built)
        #expect(model.status.isFailed)
    }

    /// Without a persisted fingerprint every cold launch would recompute and
    /// refetch shelf contents it already has.
    @Test func aColdLaunchWithAMatchingPersistedFingerprintDoesNotRefetch() async {
        let mock = configured()

        let cache = ScopedCache(store: MediaCacheStore.makeInMemory(), scope: .init(
            serverURL: URL(string: "https://example.com")!, userID: "u1",
        ))
        let first = AffinityShelvesViewModel()
        first.attach(client: mock, libraries: [moviesLibrary], cache: cache)
        await first.validate(now: now)
        let built = first.shelves
        #expect(!built.isEmpty)

        // A fresh model, as after a relaunch: hydrate from cache, then validate.
        let second = AffinityShelvesViewModel()
        second.attach(client: mock, libraries: [moviesLibrary], cache: cache)
        await second.hydrate()
        #expect(second.shelves == built)
        await second.validate(now: now)

        #expect(second.recomputeCount == 0)
        #expect(second.shelves == built)
    }

    /// The library branch already knows the universe moved; reusing an
    /// hour-old stamp would keep the old librarySize and denominators.
    @Test func reloadForcesAStampProbeInsideTheTTL() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let probesAfterFirst = mock.affinityCountRequests.filter(\.genres.isEmpty).count

        await model.validate(now: now.addingTimeInterval(60))
        #expect(mock.affinityCountRequests.filter(\.genres.isEmpty).count == probesAfterFirst)

        await model.reload(now: now.addingTimeInterval(120))
        #expect(mock.affinityCountRequests.filter(\.genres.isEmpty).count > probesAfterFirst)
    }

    @Test func aChangedLibrarySizeThrowsAwayTheCachedDenominators() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let before = mock.affinityCountRequests.filter { !$0.genres.isEmpty }.count

        mock.affinityBucketCountResult = 21
        mock.affinityLibrarySizeResult = 1001
        await model.reload(now: now.addingTimeInterval(60))
        #expect(mock.affinityCountRequests.filter { !$0.genres.isEmpty }.count > before)
    }

    /// "Stops its fetches entirely" means the requests stop, not that their
    /// results are discarded after landing.
    @Test func turningItOffCancelsTheInFlightPass() async {
        let mock = configured()
        let gate = AsyncGate()
        mock.affinityGate = gate

        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        let running = Task { await model.validate(now: now) }

        // The mock records its limit before parking on the gate, so this
        // waits for the pass to actually be in flight rather than guessing.
        for _ in 0 ..< 100 where mock.affinityMovieLimits.isEmpty {
            await Task.yield()
        }
        #expect(!mock.affinityMovieLimits.isEmpty)

        // Cancels the parked `wait()`, which throws `CancellationError` —
        // exactly how a torn-down `URLSession` request unwinds.
        await model.setEnabled(false)
        await running.value
        await gate.open()

        #expect(model.shelves.isEmpty)
        // Nothing past the signal fetch ever ran.
        #expect(mock.affinityCountRequests.isEmpty)
    }

    /// A saved-off preference must not fetch at launch.
    @Test func aModelDisabledBeforeItsFirstPassNeverFetches() async {
        let mock = MockJellyfinClient()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.setEnabled(false)
        await model.hydrate()
        await model.validate(now: now)

        #expect(mock.affinityMovieLimits.isEmpty)
        #expect(mock.affinityCountRequests.isEmpty)
    }

    /// A nil total is a refusal to count, not an empty library. Treating it
    /// as 0 would qualify nothing, drop good rows, and report success.
    @Test func aNilLibrarySizeFailsThePassAndKeepsTheRows() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let built = model.shelves
        #expect(!built.isEmpty)

        mock.affinityLibrarySizeResult = nil
        await model.retry(now: now.addingTimeInterval(7200))

        #expect(model.shelves == built)
        #expect(model.status.isFailed)
    }

    @Test func anUnchangedFingerprintLeavesTheRowsIdentical() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        let first = model.shelves

        await model.validate(now: now)
        #expect(model.shelves == first)
        #expect(model.recomputeCount == 1)
    }

    /// A failed status with no rows is what the view renders as Retry — and
    /// Retry cannot run while disabled, so it would be a dead focus target.
    @Test func turningItOffAfterAFailureDoesNotLeaveTheFailedNoticeBehind() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)

        mock.affinityFailure = MockError.boom
        await model.validate(now: now.addingTimeInterval(86400))
        #expect(model.status.isFailed)

        await model.setEnabled(false)
        #expect(model.shelves.isEmpty)
        #expect(!model.status.isFailed)
    }

    /// One newly qualifying bucket must not re-probe every bucket the cache
    /// already holds.
    @Test func aRecomputeProbesOnlyTheBucketsTheCacheIsMissing() async {
        let mock = configured()
        let model = AffinityShelvesViewModel()
        model.attach(client: mock, libraries: [moviesLibrary], cache: nil)
        await model.validate(now: now)
        // Horror and Horror|1980 cleared the floor: two filtered probes.
        let before = mock.affinityCountRequests.filter { !$0.genres.isEmpty }.count
        #expect(before == 2)

        // Three more films in a new genre move the fingerprint and add two
        // candidates; only those two are probed.
        mock.affinityMoviesResult += (0 ..< 3).map { movie("c\($0)", genres: ["Comedy"]) }
        await model.validate(now: now)
        #expect(mock.affinityCountRequests.filter { !$0.genres.isEmpty }.count == before + 2)
    }
}

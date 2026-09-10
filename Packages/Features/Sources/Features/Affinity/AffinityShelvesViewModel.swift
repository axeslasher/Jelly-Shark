import Foundation
import JellyfinKit
import Observation
import os

/// Why a pass gave up.
enum AffinityPassError: Error {
    /// The server returned no total for the unfiltered probe. Not an empty
    /// library — a refusal to count, which cannot be told apart from one and
    /// must not be treated as one.
    case missingLibrarySize
}

/// Builds Home's affinity shelves (#86): up to three rows derived from what
/// the viewer played and favorited.
///
/// A sibling of `GenreShelvesViewModel`, not part of `HomeViewModel`. It
/// borrows that shape — its own status, its own attach/reload, its own rows
/// in the focus reconciler — but not its refresh wiring: genre reloads only
/// on the library branch, while affinity's whole premise is reacting to what
/// you just watched.
///
/// Its outcome deliberately does **not** join `HomeViewModel.LoadOutcome.combine`.
/// `combine` lets any failure win, and a failed drain writes its reason back
/// into `pending` rather than retiring it — so a failing affinity pass would
/// loop Home's refresh forever. Affinity is derived decoration that must be
/// allowed to be absent.
///
/// **A pass never mutates shared state until it finishes.** Everything it
/// computes lives in locals and is published in one `commit`, guarded by the
/// pass's own token. A cancelled pass whose in-flight request lands anyway
/// therefore cannot leave a half-updated stamp or denominator set behind for
/// its replacement to read.
@Observable
@MainActor
public final class AffinityShelvesViewModel {
    public enum Status: Equatable {
        case loading
        case loaded
        /// Ran successfully and nothing qualified. Not an error, and not a
        /// reason to show anything.
        case empty
        case failed(String)

        public var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    /// Library kinds affinity derives from. Deliberately not
    /// `HomeViewModel.latestCapable`, which includes `.boxsets`: a film in a
    /// collection library would be counted there and again in its movie
    /// library, while the signal side counts it once by id.
    private static let eligibleCollectionTypes: Set<CollectionType> = [.movies, .tvshows]

    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Home")

    public private(set) var shelves: [CachedAffinityShelf] = []
    public private(set) var status: Status = .loading

    /// Counts for tests: how many signals the engine last received, and how
    /// many times a recompute actually ran.
    private(set) var lastSignalCount = 0
    private(set) var recomputeCount = 0

    private var client: (any JellyfinClientProtocol)?
    private var cache: ScopedCache?
    private var eligibleLibraryIDs: [String] = []
    private var isEnabled = true

    /// The shelf set as last built, kept across a toggle-off so turning it
    /// back on is instant.
    private var builtShelves: [CachedAffinityShelf] = []

    /// A fingerprint this session actually validated against the server.
    private var validatedFingerprint: String?

    /// The fingerprint that was persisted alongside the hydrated rows.
    ///
    /// A persisted fingerprint is not evidence that server state is
    /// unchanged — only a pass that actually fetched signals establishes
    /// that. But it *is* what the hydrated rows were built from, so a fresh
    /// pass matching it means those rows are still right and must be left
    /// alone. Without this, every cold launch recomputes and refetches shelf
    /// contents it already has.
    private var persistedFingerprint: String?

    /// How strong a refresh a pass is.
    ///
    /// Ordered, so a refresh that arrives while the toggle is off can be
    /// remembered at its real strength. A `.libraries` drain downgraded to a
    /// plain `validate()` on re-enable would reuse the stamp and
    /// denominators inside their TTLs — on the one path that knows the
    /// library moved.
    private enum PassStrength: Int, Comparable {
        case validate
        case reload

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Work that was asked for but never successfully completed — a refresh
    /// that arrived while the toggle was off, a pass that failed, or a pass
    /// cancelled by the toggle going off mid-flight.
    ///
    /// One field for all three, because they mean the same thing: the
    /// validated fingerprint no longer proves the rows are current, and the
    /// strength of what was owed must not be downgraded. Nil means nothing
    /// is owed and re-enabling can restore the rows without touching the
    /// network.
    private var owedStrength: PassStrength?

    /// The strength of the pass currently in flight, so cancelling it can
    /// put its work back on the books.
    private var activeStrength: PassStrength?

    /// The in-flight pass, so turning the toggle off can genuinely cancel it
    /// rather than merely discard its result.
    private var passTask: Task<Void, Never>?

    /// Identifies the current pass. A pass commits only if this still names
    /// it — a cancelled pass whose request landed anyway must publish
    /// nothing.
    private var currentPassToken = 0

    private var stamp: AffinityLibraryStamp?
    private var stampProbedAt: Date?
    private var denominators: [AffinityBucket: Int] = [:]
    private var denominatorsProbedAt: Date?

    public init() {}

    /// Everything a pass reads from the model, captured before its first
    /// suspension.
    ///
    /// A pass runs across many awaits, and `attach` can replace the client,
    /// the library set, and the cache while it does. Reading those fields
    /// mid-pass would let an old pass combine a stale client's response with
    /// a new server's library ids and write the hybrid to the new server's
    /// cache.
    private struct PassContext {
        let client: any JellyfinClientProtocol
        let libraryIDs: [String]
        let cache: ScopedCache?
    }

    private func owe(_ strength: PassStrength) {
        owedStrength = max(owedStrength ?? strength, strength)
    }

    /// - Parameter libraries: the connection's browsable library list, so
    ///   the stamp costs no extra round-trip. `RootView` already holds it,
    ///   `isBrowsable`-filtered.
    public func attach(
        client: (any JellyfinClientProtocol)?,
        libraries: [Library],
        cache: ScopedCache?,
    ) {
        let eligible = libraries
            .filter { $0.collectionType.map(Self.eligibleCollectionTypes.contains) ?? false }
            .map(\.id)
            .sorted()
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let librariesChanged = eligible != eligibleLibraryIDs
        // The scope alone can move with the client and library set
        // unchanged — a profile switch on the same server. Missing it would
        // let a pass that measured the old profile publish into a model that
        // now represents the new one, and let an in-flight hydration from
        // the old profile's cache pass its token check.
        let scopeChanged = cache?.scope != self.cache?.scope

        self.client = client
        self.cache = cache
        eligibleLibraryIDs = eligible

        guard clientChanged || librariesChanged || scopeChanged else { return }

        // A pass in flight was measuring a different universe. Cancel it and
        // advance the token so it can commit nothing, and drop every piece
        // of server-specific state it might have left behind.
        passTask?.cancel()
        passTask = nil
        currentPassToken += 1
        if let activeStrength {
            owe(activeStrength)
        }
        activeStrength = nil

        validatedFingerprint = nil
        persistedFingerprint = nil
        stamp = nil
        stampProbedAt = nil
        denominators = [:]
        denominatorsProbedAt = nil

        // A different client or a different scope is a different person.
        // Their rows go immediately, not when a replacement arrives — a
        // failed validation or an empty cache would otherwise leave the
        // previous profile's recommendations on screen indefinitely. This is
        // the same privacy boundary `RootView` enforces by rebuilding
        // `genreShelves` on sign-out.
        //
        // A same-profile library change keeps them: the rows are still this
        // viewer's, and blanking Home to re-derive identical shelves is a
        // focus-graph churn nobody asked for.
        guard clientChanged || scopeChanged else { return }
        builtShelves = []
        shelves = []
        status = .loading
    }

    /// Show the cached rows immediately, with no fingerprint check and no
    /// network. The fingerprint is computed from freshly fetched signals, so
    /// checking it first would mean waiting on the network — the exact delay
    /// persisting items exists to avoid.
    public func hydrate() async {
        guard isEnabled, let cache else { return }
        let token = currentPassToken
        guard let cached = await cache.read(CachedAffinityShelves.self, key: .affinityShelves) else { return }

        // The read suspended. A toggle-off or a profile change since would
        // have advanced the token — publishing here anyway would repaint
        // rows while disabled, or paint one profile's rows over another's.
        // Both `setEnabled` and a meaningful `attach` advance it.
        guard isEnabled, token == currentPassToken else { return }

        builtShelves = cached.shelves
        shelves = cached.shelves
        persistedFingerprint = cached.fingerprint
        stamp = cached.stamp
        stampProbedAt = cached.stampProbedAt
        denominators = cached.denominators
        denominatorsProbedAt = cached.denominatorsProbedAt
        status = cached.shelves.isEmpty ? .empty : .loaded
    }

    /// Fetch the signals, compare the fingerprint, and recompute only if it
    /// moved. Safe to call on every Home load and every watch-state refresh.
    public func validate(now: Date = .now) async {
        await run(strength: .validate, now: now)
    }

    /// The library branch's entry point: re-probe the stamp and rebuild the
    /// shelves, whatever the fingerprint says.
    ///
    /// `validate()` is not enough here, twice over. It would reuse an
    /// up-to-hour-old stamp on the one code path that already knows the
    /// library changed; and if the library's id set and item count happen to
    /// be unchanged, the fingerprint would match and it would skip the
    /// rebuild entirely.
    public func reload(now: Date = .now) async {
        await run(strength: .reload, now: now)
    }

    public func retry(now: Date = .now) async {
        validatedFingerprint = nil
        persistedFingerprint = nil
        await run(strength: .reload, now: now)
    }

    /// Off cancels an in-flight pass and clears the rows without clearing
    /// the cache, so turning it back on is instant. On restores the rows and
    /// starts a pass only if there is reason to believe anything moved.
    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        // Cancel, not just supersede: "stops its fetches entirely" means the
        // requests stop, not that their results are discarded after landing.
        // The cancelled pass's work goes back on the books — a `.libraries`
        // refresh interrupted here must not come back as a `.validate`.
        if let activeStrength {
            owe(activeStrength)
        }
        activeStrength = nil
        passTask?.cancel()
        passTask = nil
        currentPassToken += 1

        guard enabled else {
            shelves = []
            // `.empty`, not left as it was: a `.failed` status with no rows
            // is exactly what the view renders as the Retry notice — and
            // Retry cannot run while disabled, so it would sit there as a
            // dead focus target until the toggle came back on.
            status = .empty
            return
        }

        shelves = builtShelves
        status = builtShelves.isEmpty ? .empty : .loaded

        // A fingerprint validated this session, with nothing owed since,
        // means the rows are known-current and the network can be left
        // alone entirely. `run` reads the debt back, so the strength passed
        // here is only a floor.
        let neverValidated: PassStrength? = validatedFingerprint == nil ? .validate : nil
        guard let pending = owedStrength ?? neverValidated else { return }

        switch pending {
        case .validate: await validate()
        case .reload: await reload()
        }
    }

    // MARK: - The pass

    private func run(strength: PassStrength, now: Date) async {
        // Every request goes on the books first, and the debt is only
        // cleared by a pass that succeeds. This is what stops a `.validate`
        // arriving after a failed — or superseded — `.reload` from running
        // at the weaker strength, matching the old fingerprint, and then
        // wiping the debt it never paid.
        if let activeStrength {
            owe(activeStrength)
        }
        owe(strength)

        // Booked even with no client: `attach` keeps the debt, so the first
        // pass after a client arrives runs at the strength that was owed.
        guard isEnabled, let client else { return }

        let effective = owedStrength ?? strength
        passTask?.cancel()
        currentPassToken += 1
        let token = currentPassToken
        activeStrength = effective

        // Captured now, never read from the model again: `attach` may
        // replace all three while this pass is suspended.
        let context = PassContext(client: client, libraryIDs: eligibleLibraryIDs, cache: cache)
        let task = Task {
            await pass(token: token, strength: effective, context: context, now: now)
        }
        passTask = task

        // The `Task` is unstructured, so cancelling the caller — Home's
        // revision-keyed drain task, which is routinely superseded — would
        // otherwise leave this pass running and this `await` hanging on it.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func pass(token: Int, strength: PassStrength, context: PassContext, now: Date) async {
        let client = context.client
        defer {
            if token == currentPassToken {
                activeStrength = nil
            }
        }
        do {
            let signals = try await fetchSignals(client: client)
            try Task.checkCancellation()

            let probed = try await probeStamp(context: context, now: now, forcing: strength == .reload)
            try Task.checkCancellation()

            let fingerprint = AffinityFingerprint.make(
                signals: signals.normalized,
                favoritedPeople: signals.people,
                now: now,
                stamp: probed.stamp,
            )

            // Match against what this session validated *or* what the
            // hydrated rows were built from. The second is what makes a cold
            // launch cheap. A `.reload` bypasses both.
            let unchanged = fingerprint == validatedFingerprint || fingerprint == persistedFingerprint
            if unchanged, strength != .reload {
                guard token == currentPassToken else { return }
                Self.logger.debug("affinity fingerprint unchanged")
                lastSignalCount = signals.normalized.count
                validatedFingerprint = fingerprint
                owedStrength = nil
                // `commitProbeOnly` also clears a previous failure: without
                // that, an empty model keeps showing Retry forever once one
                // pass has failed, however many succeed after it. The row it
                // returns carries the refreshed probe timestamp, so the next
                // launch does not repeat a size probe this session just did.
                if let row = commitProbeOnly(probed, now: now) {
                    await persist(row, context: context)
                }
                return
            }

            let result = try await build(
                client: client,
                signals: signals,
                probed: probed,
                fingerprint: fingerprint,
                now: now,
            )
            try Task.checkCancellation()

            guard token == currentPassToken else { return }
            lastSignalCount = signals.normalized.count
            recomputeCount += 1
            owedStrength = nil
            await persist(commit(result, now: now), context: context)
        } catch is CancellationError {
            return
        } catch {
            guard token == currentPassToken, !Task.isCancelled else { return }
            // Keep whatever rows are showing: a rendered shelf disappearing
            // over a refresh failure reads as data loss.
            Self.logger.debug("affinity pass failed: \(PlaybackLog.error(error), privacy: .public)")
            status = .failed("Couldn't refresh your picks")
            // A failure proves nothing about freshness. Without this, a
            // toggle off and back on would treat the stale rows as
            // known-current, clear the failure, and skip the retry — and a
            // failed `.reload` would come back as a `.validate`.
            validatedFingerprint = nil
            owe(strength)
        }
    }

    // MARK: - Fetching

    private struct Signals {
        let normalized: [AffinitySignal]
        let people: [Person]
    }

    /// A probed stamp and whether it invalidates the cached denominators.
    /// Returned rather than assigned, so a cancelled pass publishes nothing.
    private struct ProbedStamp {
        let stamp: AffinityLibraryStamp
        let isFresh: Bool
        let invalidatesDenominators: Bool
    }

    private struct PassResult {
        let probed: ProbedStamp
        let denominators: [AffinityBucket: Int]
        let denominatorsAreFresh: Bool
        let fingerprint: String
        let shelves: [CachedAffinityShelf]
    }

    /// Stage one is four concurrent fetches. Stage two — series hydration —
    /// cannot start until the episode window returns, because its input is
    /// the collapsed series id set. An all-films history finishes in one
    /// stage; any TV takes two.
    private func fetchSignals(client: any JellyfinClientProtocol) async throws -> Signals {
        async let movies = client.recentlyPlayedMoviesForAffinity(limit: AffinityTuning.playedMovieLimit)
        async let episodes = client.recentlyPlayedEpisodesForAffinity(limit: AffinityTuning.playedEpisodeLimit)
        async let favorites = client.favoritedItemsForAffinity(limit: AffinityTuning.favoritedItemLimit)
        async let people = client.favoritedPeople()

        let (playedMovies, playedEpisodes, favoritedItems, favoritedPeople) =
            try await (movies, episodes, favorites, people)

        let seriesIDs = Set(playedEpisodes.compactMap(\.seriesId)).sorted()
        let seriesMetadata = seriesIDs.isEmpty ? [] : try await client.itemsForAffinity(ids: seriesIDs)

        return Signals(
            normalized: AffinityNormalizer.normalize(
                playedMovies: playedMovies,
                playedEpisodes: playedEpisodes,
                seriesMetadata: seriesMetadata,
                favoritedItems: favoritedItems,
                favoritedPeople: favoritedPeople,
            ),
            people: favoritedPeople,
        )
    }

    /// Reuses the last probe inside `stampTTL`, so a burst of returns from
    /// playback costs nothing — unless `forcing`, which the library branch
    /// passes because it already knows the universe moved.
    ///
    /// The library ids come from `attach`, not from a `getLibraries()` call:
    /// `RootView` already holds the browsable list, and fetching it here
    /// would add a serial round-trip that § 8.2's cost table does not carry.
    private func probeStamp(
        context: PassContext,
        now: Date,
        forcing: Bool,
    ) async throws -> ProbedStamp {
        if !forcing, let stamp, let probedAt = stampProbedAt,
           now.timeIntervalSince(probedAt) < AffinityTuning.stampTTL
        {
            return ProbedStamp(stamp: stamp, isFresh: false, invalidatesDenominators: false)
        }

        // A nil total is the server declining to count, not an empty
        // library. Treating it as 0 would qualify nothing, replace good rows
        // with none, and report success — a silent failure.
        guard let size = try await context.client.affinityItemCount(genres: [], decades: [], personID: nil) else {
            throw AffinityPassError.missingLibrarySize
        }

        let fresh = AffinityLibraryStamp(libraryIDs: context.libraryIDs, librarySize: size)
        // A moved stamp means the counts under it described a different
        // universe. They can never be read back against this one.
        return ProbedStamp(stamp: fresh, isFresh: true, invalidatesDenominators: fresh != stamp)
    }

    private func build(
        client: any JellyfinClientProtocol,
        signals: Signals,
        probed: ProbedStamp,
        fingerprint: String,
        now: Date,
    ) async throws -> PassResult {
        let scores = AffinityScoring.score(signals: signals.normalized, favoritedPeople: signals.people, now: now)
        let candidates = AffinityThreshold.candidateBuckets(scores: scores)

        let (counts, countsAreFresh) = try await denominators(
            client: client,
            buckets: candidates,
            invalidated: probed.invalidatesDenominators,
            now: now,
        )
        try Task.checkCancellation()

        let qualifying = AffinityThreshold.qualifying(
            scores: scores,
            denominators: counts,
            librarySize: probed.stamp.librarySize,
        )
        let descriptors = AffinitySelection.select(
            signals: signals.normalized,
            scores: scores,
            qualifying: qualifying,
        )

        var built: [(AffinityShelfDescriptor, [MediaItem])] = []
        for descriptor in descriptors {
            let items = try await items(for: descriptor, client: client)
            try Task.checkCancellation()
            built.append((descriptor, items))
        }

        return PassResult(
            probed: probed,
            denominators: counts,
            denominatorsAreFresh: countsAreFresh,
            fingerprint: fingerprint,
            shelves: AffinitySelection.deOverlap(shelves: built)
                .map { CachedAffinityShelf(descriptor: $0.0, items: $0.1) },
        )
    }

    /// Probes only buckets that already cleared the floor, and of those only
    /// the ones the cache does not hold — one newly qualifying bucket must
    /// not cost a re-probe of every other. A full re-probe happens only when
    /// the counts have expired or the universe moved.
    ///
    /// Returns whether the whole map is fresh. A partial top-up keeps the
    /// cached map's timestamp, so it still expires on the old schedule.
    private func denominators(
        client: any JellyfinClientProtocol,
        buckets: [AffinityBucket],
        invalidated: Bool,
        now: Date,
    ) async throws -> ([AffinityBucket: Int], Bool) {
        let cacheIsUsable = !invalidated
            && denominatorsProbedAt.map { now.timeIntervalSince($0) < AffinityTuning.denominatorTTL } == true
        let cached = cacheIsUsable ? denominators : [:]
        let missing = buckets.filter { cached[$0] == nil }
        guard !missing.isEmpty else { return (cached, false) }

        let probed = try await probeCounts(for: missing, client: client)
        return (cached.merging(probed) { _, fresh in fresh }, !cacheIsUsable)
    }

    /// One count request per bucket, a few in flight at a time. The probes
    /// are independent, so serializing them only adds latency; the window is
    /// bounded so a wide candidate set cannot swamp the connection pool the
    /// artwork loads share.
    private func probeCounts(
        for buckets: [AffinityBucket],
        client: any JellyfinClientProtocol,
    ) async throws -> [AffinityBucket: Int] {
        try await withThrowingTaskGroup(of: (AffinityBucket, Int?).self) { group in
            var counts: [AffinityBucket: Int] = [:]
            var pending = buckets[...]

            func enqueue(_ bucket: AffinityBucket) {
                group.addTask {
                    let count: Int? = switch bucket {
                    case let .genre(name):
                        try await client.affinityItemCount(genres: [name], decades: [], personID: nil)
                    case let .genreDecade(name, decade):
                        try await client.affinityItemCount(genres: [name], decades: [decade], personID: nil)
                    case let .person(id):
                        try await client.affinityItemCount(genres: [], decades: [], personID: id)
                    }
                    return (bucket, count)
                }
            }

            for bucket in pending.prefix(AffinityTuning.probeConcurrency) {
                enqueue(bucket)
            }
            pending = pending.dropFirst(AffinityTuning.probeConcurrency)

            for try await (bucket, count) in group {
                if let count {
                    counts[bucket] = count
                }
                if let next = pending.popFirst() {
                    enqueue(next)
                }
            }
            return counts
        }
    }

    private func items(
        for descriptor: AffinityShelfDescriptor,
        client: any JellyfinClientProtocol,
    ) async throws -> [MediaItem] {
        switch descriptor.kind {
        case let .similar(seedID, _, _):
            try await client.getSimilarItems(itemId: seedID, limit: AffinityTuning.shelfItemLimit)
        case let .bucket(.person(id)):
            // `personTypes: nil` and movies-and-series only, so the shelf's
            // contents match the population its ratio was measured against.
            try await client.getItemsFeaturingPerson(
                personId: id,
                itemTypes: [.movie, .series],
                personTypes: nil,
                limit: AffinityTuning.shelfItemLimit,
            )
        case let .bucket(.genre(name)):
            try await shelfItems(query: LibraryQuery(genres: [name]), client: client)
        case let .bucket(.genreDecade(name, decade)):
            try await shelfItems(query: LibraryQuery(genres: [name], decades: [decade]), client: client)
        }
    }

    private func shelfItems(
        query: LibraryQuery,
        client: any JellyfinClientProtocol,
    ) async throws -> [MediaItem] {
        try await client.getLibraryItems(
            libraryId: nil,
            itemTypes: [.movie, .series],
            query: query,
            limit: AffinityTuning.shelfItemLimit,
            startIndex: 0,
        ).items
    }

    // MARK: - Publishing

    /// The only place a fingerprint-unchanged pass touches shared state.
    private func commitProbe(_ probed: ProbedStamp, now: Date) {
        guard probed.isFresh else { return }
        stamp = probed.stamp
        stampProbedAt = now
        if probed.invalidatesDenominators {
            denominators = [:]
            denominatorsProbedAt = nil
        }
    }

    /// Publish, and return the row to persist.
    ///
    /// The payload is built here, synchronously, from values this pass owns
    /// — never re-read from the model after a suspension. Every `persist`
    /// below therefore writes a self-consistent row, and a newer pass
    /// overwriting it is last-writer-wins with correct data rather than a
    /// hybrid of two passes.
    private func commit(_ result: PassResult, now: Date) -> CachedAffinityShelves {
        commitProbe(result.probed, now: now)
        denominators = result.denominators
        if result.denominatorsAreFresh {
            denominatorsProbedAt = now
        }
        builtShelves = result.shelves
        shelves = result.shelves
        status = result.shelves.isEmpty ? .empty : .loaded
        validatedFingerprint = result.fingerprint
        persistedFingerprint = result.fingerprint

        return CachedAffinityShelves(
            fingerprint: result.fingerprint,
            stamp: result.probed.stamp,
            stampProbedAt: stampProbedAt ?? now,
            denominators: denominators,
            denominatorsProbedAt: denominatorsProbedAt ?? now,
            shelves: result.shelves,
        )
    }

    /// The fingerprint-unchanged equivalent: refresh the row's freshness
    /// metadata, keep its rows and fingerprint.
    ///
    /// Built from in-memory state with **no cache read** — the rows and
    /// fingerprint are already `builtShelves` and `persistedFingerprint`, so
    /// reading them back would only add a suspension for a newer pass to
    /// interleave with. Returns nil when there is nothing durable to
    /// rewrite.
    private func commitProbeOnly(_ probed: ProbedStamp, now: Date) -> CachedAffinityShelves? {
        // The stamp is one of the fingerprint's inputs, so "unchanged" here
        // implies the stamp did not move and `commitProbe` cannot be
        // emptying the denominators on this path. If the fingerprint ever
        // stops covering the stamp, that invariant goes with it.
        commitProbe(probed, now: now)
        status = builtShelves.isEmpty ? .empty : .loaded

        guard probed.isFresh, let fingerprint = persistedFingerprint else { return nil }
        return CachedAffinityShelves(
            fingerprint: fingerprint,
            stamp: probed.stamp,
            stampProbedAt: stampProbedAt ?? now,
            denominators: denominators,
            denominatorsProbedAt: denominatorsProbedAt ?? now,
            shelves: builtShelves,
        )
    }

    /// Write one already-built row to the cache this pass started with.
    ///
    /// `context.cache`, not `self.cache`: `attach` may have pointed the
    /// model at a different profile's scope while this pass was suspended,
    /// and a row measured against the old server must never land in the new
    /// one's cache.
    private func persist(_ row: CachedAffinityShelves, context: PassContext) async {
        guard let cache = context.cache else { return }
        await cache.write(row, key: .affinityShelves)
    }
}

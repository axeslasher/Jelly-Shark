import Foundation
import OSLog
import SwiftData

// MARK: - Models

/// One cached payload: a Codable blob keyed by scope + entry key. The blob's
/// Swift type is fixed by the `CacheSnapshotKey` that wrote it.
@Model
final class CachedSnapshot {
    #Unique<CachedSnapshot>([\.scopeKey, \.entryKey])

    var scopeKey: String
    var entryKey: String
    var kind: String
    var payload: Data
    var updatedAt: Date

    init(scopeKey: String, entryKey: String, kind: String, payload: Data, updatedAt: Date) {
        self.scopeKey = scopeKey
        self.entryKey = entryKey
        self.kind = kind
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

/// One item's user state (watched, favorite, resume position) as the server
/// last reported it — the cold-start seed for the user-state overlay.
@Model
final class CachedUserState {
    #Unique<CachedUserState>([\.scopeKey, \.itemID])

    var scopeKey: String
    var itemID: String
    var played: Bool
    var isFavorite: Bool
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var lastPlayedDate: Date?
    var updatedAt: Date

    init(scopeKey: String, itemID: String, value: CachedUserStateValue, updatedAt: Date) {
        self.scopeKey = scopeKey
        self.itemID = itemID
        played = value.played
        isFavorite = value.isFavorite
        playbackPositionTicks = value.playbackPositionTicks
        playCount = value.playCount
        lastPlayedDate = value.lastPlayedDate
        self.updatedAt = updatedAt
    }

    var value: CachedUserStateValue {
        get {
            CachedUserStateValue(
                played: played,
                isFavorite: isFavorite,
                playbackPositionTicks: playbackPositionTicks,
                playCount: playCount,
                lastPlayedDate: lastPlayedDate,
            )
        }
        set {
            played = newValue.played
            isFavorite = newValue.isFavorite
            playbackPositionTicks = newValue.playbackPositionTicks
            playCount = newValue.playCount
            lastPlayedDate = newValue.lastPlayedDate
        }
    }
}

/// A `CachedUserState` row as a value, so state never crosses the actor
/// boundary as a live model object
public struct CachedUserStateValue: Sendable, Equatable {
    public var played: Bool
    public var isFavorite: Bool
    public var playbackPositionTicks: Int64?
    public var playCount: Int?
    public var lastPlayedDate: Date?

    public init(
        played: Bool = false,
        isFavorite: Bool = false,
        playbackPositionTicks: Int64? = nil,
        playCount: Int? = nil,
        lastPlayedDate: Date? = nil,
    ) {
        self.played = played
        self.isFavorite = isFavorite
        self.playbackPositionTicks = playbackPositionTicks
        self.playCount = playCount
        self.lastPlayedDate = lastPlayedDate
    }
}

// MARK: - Store

/// The SwiftData-backed cache behind the app's cache-then-network reads.
///
/// Display acceleration only — the server stays the source of truth, and
/// every cached render is followed by a network refresh. That contract is
/// why every failure path here degrades to a cache miss instead of an error:
/// a cache that can take the app down is worse than no cache.
///
/// Degrading silently is a different thing from degrading gracefully, though,
/// and this store used to do both. Every failure is now logged to the
/// `Cache` category — nothing changes for the caller, but a store that has
/// quietly stopped caching is a `log show --predicate 'category == "Cache"'`
/// away instead of being invisible until someone notices cold starts got
/// slower. **Scope keys and item ids never appear in a log line**: they carry
/// the server URL and the user id, so messages carry the payload `kind`
/// (a fixed six-value set) and row counts instead.
///
/// That rule has a non-obvious second half. Only *bounded* values are marked
/// `privacy: .public`; a caught error never is, because `\(error)` renders an
/// `NSError`'s whole `userInfo` and Core Data puts row-bearing keys in there.
/// `label(_:)` publishes the domain and code, and the error rides along
/// redacted. Anything added here should follow the same split.
///
/// There are deliberately **no SwiftData migrations**. `schemaVersion`
/// covers the `@Model` shapes, the Codable payload encodings, and the key
/// formats; any mismatch (or any store the current code cannot open) deletes
/// the store files and starts empty. The server rebuilds the contents, so
/// migration machinery would preserve data that is free to re-fetch.
///
/// An actor rather than `@MainActor`: the write fan-out after a load
/// (a multi-hundred-KB blob plus user-state upserts for ~100 items) must not
/// compete with the focus engine on the main thread, and a hydration read is
/// one indexed fetch + decode — the actor hop costs nothing that matters.
@ModelActor
public actor MediaCacheStore {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Cache")

    /// Bump when anything about the on-disk format changes: a `@Model`
    /// shape, a cached Codable model, or a key format. The old store is
    /// wiped and refilled from the server — never migrated.
    /// v2: `MediaItem` gained `mediaSources` (#147).
    static let schemaVersion = 2

    static let versionDefaultsKey = "mediaCacheSchemaVersion"

    private static var schema: Schema {
        Schema([CachedSnapshot.self, CachedUserState.self])
    }

    // MARK: Factories

    /// The production store, under Caches on purpose: tvOS treats bulk local
    /// storage as evictable, and eviction is semantically fine here — the
    /// server refills anything the OS reclaims.
    public static func makePersistent() -> MediaCacheStore {
        makePersistent(
            directory: URL.cachesDirectory.appending(path: "MediaCache", directoryHint: .isDirectory),
            defaults: .standard,
            version: schemaVersion,
        )
    }

    /// An isolated store for tests and previews; no files, no version key
    public static func makeInMemory() -> MediaCacheStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        // In-memory container creation does no I/O; it can only fail if the
        // schema itself is invalid, which no release build can reach.
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return MediaCacheStore(modelContainer: container)
    }

    /// Internal seam so host tests can run the version-wipe and
    /// corrupt-store paths against a scratch directory and defaults suite
    static func makePersistent(directory: URL, defaults: UserDefaults, version: Int) -> MediaCacheStore {
        let storeURL = directory.appending(path: "MediaCache.store")

        let stored = defaults.integer(forKey: versionDefaultsKey)
        if stored != version {
            // `stored == 0` is a first launch, not a wipe — there is nothing
            // on disk yet, so saying so would be noise on every install.
            if stored != 0 {
                logger.notice("[cache] schema version \(stored) → \(version); wiping the store")
            }
            removeStoreFiles(at: storeURL)
        }
        defaults.set(version, forKey: versionDefaultsKey)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("[cache] could not create the store directory: \(label(error), privacy: .public) — \(error)")
        }
        let configuration = ModelConfiguration(url: storeURL)

        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return MediaCacheStore(modelContainer: container)
        }
        // A store the current code cannot open is a corrupt or stale cache:
        // destroy it and retry once with a fresh file
        logger.error("[cache] the store would not open; deleting it and retrying once")
        removeStoreFiles(at: storeURL)
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            logger.notice("[cache] store rebuilt empty after the failed open")
            return MediaCacheStore(modelContainer: container)
        }
        // Still failing means the directory itself is unusable; the cache
        // goes inert (in-memory) rather than taking the app down
        logger.error("[cache] the store is unusable; caching is disabled for this launch")
        return makeInMemory()
    }

    private static func removeStoreFiles(at storeURL: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(filePath: storeURL.path + suffix)
            // A store that was never created has no sidecars to remove, so
            // only a failure to delete a file that *is* there is a real event
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try manager.removeItem(at: url)
            } catch {
                let name = suffix.isEmpty ? "store" : suffix
                logger.error(
                    "[cache] could not delete the \(name, privacy: .public) file: \(label(error), privacy: .public) — \(error)",
                )
            }
        }
    }

    // MARK: Failure reporting

    /// An error's domain and code — bounded framework constants, and the only
    /// part of an error this file publishes.
    ///
    /// The error *itself* is never interpolated at `.public` here, which is
    /// the whole reason this exists. `\(error)` bridges to `NSError` and logs
    /// it as an object, so the rendered string is `NSError.description` — and
    /// that includes the entire `userInfo`. Core Data fills `userInfo` with
    /// row-bearing keys on precisely the failures this store hits: a `#Unique`
    /// violation (133020/133021) arrives as a `conflictList` naming
    /// `scopeKey` and `entryKey` verbatim, and both of this store's
    /// constraints are composed of exactly those fields. Publishing that would
    /// put the server URL, the user id, and an item id in the unified log,
    /// where they persist into any sysdiagnose attached to a bug report.
    ///
    /// Callers pair this with a bare `\(error)` at default privacy, so the
    /// full detail is still readable on a development device with a logging
    /// profile installed and redacted everywhere else.
    private static func label(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// `modelContext.save()`, reported instead of discarded. Callers still
    /// carry on: an unsaved write is a future cache miss, which is the whole
    /// contract of this store — but a store failing every save should not
    /// take an entire release to notice.
    ///
    /// `operation` is a `StaticString` so it cannot be built from a runtime
    /// value — which is what makes publishing it provably safe. It still needs
    /// the explicit `privacy: .public`: `OSLogInterpolation` has no
    /// `StaticString` overload, so it binds to the generic
    /// `CustomStringConvertible` one, whose default `.auto` privacy redacts
    /// dynamic strings. Only a literal baked into the format string is public
    /// without saying so.
    private func save(after operation: StaticString) {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error(
                "[cache] save failed after \(operation, privacy: .public): \(Self.label(error), privacy: .public) — \(error)",
            )
        }
    }

    /// `modelContext.fetch(_:)`, reported instead of discarded. Returns an
    /// empty array on failure, which every caller already treats as a miss.
    /// See `save(after:)` for why `operation` is a `StaticString` and still
    /// carries an explicit privacy annotation.
    private func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        during operation: StaticString,
    ) -> [T] {
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            Self.logger.error(
                "[cache] fetch failed during \(operation, privacy: .public): \(Self.label(error), privacy: .public) — \(error)",
            )
            return []
        }
    }

    // MARK: Snapshots

    /// The blob under `key`, or nil on any miss — absent, undecodable
    /// (stale format), whatever. An undecodable row is deleted so it cannot
    /// fail again.
    public func read<T: Decodable & Sendable>(
        _ type: T.Type,
        scope: CacheScope,
        key: CacheSnapshotKey,
    ) -> T? {
        guard let row = snapshotRow(scope: scope, key: key) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: row.payload) else {
            // The version-wipe policy is supposed to make this unreachable —
            // a payload encoding change requires a `schemaVersion` bump — so
            // reaching it means a bump was missed. Worth a line.
            Self.logger.warning("[cache] undecodable \(key.kind, privacy: .public) row; deleting it")
            modelContext.delete(row)
            save(after: "read")
            return nil
        }
        return value
    }

    /// Persist `value` under `key`, replacing any previous blob. Failures
    /// are swallowed: a cache write that cannot land is a future cache miss,
    /// not an error the caller can act on.
    public func write(_ value: some Encodable & Sendable, scope: CacheScope, key: CacheSnapshotKey) {
        guard let payload = try? JSONEncoder().encode(value) else {
            // A domain model that will not encode is a code defect, not a
            // transient — it fails identically on every launch forever.
            Self.logger.error("[cache] could not encode a \(key.kind, privacy: .public) payload; not cached")
            return
        }
        if let row = snapshotRow(scope: scope, key: key) {
            row.payload = payload
            row.updatedAt = Date()
        } else {
            modelContext.insert(CachedSnapshot(
                scopeKey: scope.storageKey,
                entryKey: key.storageKey,
                kind: key.kind,
                payload: payload,
                updatedAt: Date(),
            ))
        }
        save(after: "write")
    }

    private func snapshotRow(scope: CacheScope, key: CacheSnapshotKey) -> CachedSnapshot? {
        let scopeKey = scope.storageKey
        let entryKey = key.storageKey
        var descriptor = FetchDescriptor<CachedSnapshot>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.entryKey == entryKey },
        )
        descriptor.fetchLimit = 1
        return fetch(descriptor, during: "snapshotRow").first
    }

    // MARK: User state

    /// Every stored user-state row for the scope, keyed by item id — the
    /// cold-start seed for `UserStateStore`'s in-memory overlay
    public func allUserStates(scope: CacheScope) -> [String: CachedUserStateValue] {
        let scopeKey = scope.storageKey
        let descriptor = FetchDescriptor<CachedUserState>(
            predicate: #Predicate { $0.scopeKey == scopeKey },
        )
        let rows = fetch(descriptor, during: "allUserStates")
        return Dictionary(rows.map { ($0.itemID, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// The stored user state for the given items, keyed by item id
    public func userStates(scope: CacheScope, itemIDs: [String]) -> [String: CachedUserStateValue] {
        let scopeKey = scope.storageKey
        let descriptor = FetchDescriptor<CachedUserState>(
            predicate: #Predicate { $0.scopeKey == scopeKey && itemIDs.contains($0.itemID) },
        )
        let rows = fetch(descriptor, during: "userStates")
        return Dictionary(rows.map { ($0.itemID, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// Record what the server just said about these items' user data.
    /// Items without `userData` (or without a real id) are skipped, not
    /// zeroed — absence of the field is not a statement about the state.
    public func ingestServerUserData(scope: CacheScope, items: [MediaItem]) {
        let scopeKey = scope.storageKey
        let reported = items.filter { $0.userData != nil && !$0.id.isEmpty }
        guard !reported.isEmpty else { return }

        // Same id twice in one response (an episode on two shelves): the
        // later entry wins, matching the order the server sent them
        let byID = Dictionary(reported.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = Array(byID.keys)
        let descriptor = FetchDescriptor<CachedUserState>(
            predicate: #Predicate { $0.scopeKey == scopeKey && ids.contains($0.itemID) },
        )
        var rows = Dictionary(
            fetch(descriptor, during: "ingestServerUserData").map { ($0.itemID, $0) },
            uniquingKeysWith: { _, last in last },
        )

        for (id, item) in byID {
            guard let data = item.userData else { continue }
            let value = CachedUserStateValue(
                played: data.played,
                isFavorite: data.isFavorite,
                playbackPositionTicks: data.playbackPositionTicks,
                playCount: data.playCount,
                lastPlayedDate: data.lastPlayedDate,
            )
            if let row = rows[id] {
                row.value = value
                row.updatedAt = Date()
            } else {
                let row = CachedUserState(scopeKey: scopeKey, itemID: id, value: value, updatedAt: Date())
                modelContext.insert(row)
                rows[id] = row
            }
        }
        save(after: "ingestServerUserData")
    }

    /// Apply a local, server-acknowledged change (a successful
    /// `markPlayed`-style call) to one item's stored state, creating the row
    /// if the item was never fetched
    public func setUserState(
        scope: CacheScope,
        itemID: String,
        mutating mutate: @Sendable (inout CachedUserStateValue) -> Void,
    ) {
        let scopeKey = scope.storageKey
        var descriptor = FetchDescriptor<CachedUserState>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.itemID == itemID },
        )
        descriptor.fetchLimit = 1

        if let row = fetch(descriptor, during: "setUserState").first {
            var value = row.value
            mutate(&value)
            row.value = value
            row.updatedAt = Date()
        } else {
            var value = CachedUserStateValue()
            mutate(&value)
            modelContext.insert(CachedUserState(scopeKey: scopeKey, itemID: itemID, value: value, updatedAt: Date()))
        }
        save(after: "setUserState")
    }

    // MARK: Purging

    /// Forget everything cached for one server + user. Sign-out's privacy
    /// boundary, and the eventual "forget profile" (#192).
    public func purge(scope: CacheScope) {
        let scopeKey = scope.storageKey
        // A purge that silently fails leaves one user's rows readable to the
        // next sign-in, so this is the one failure here that is a privacy
        // event rather than a performance one. It still cannot throw at the
        // caller — sign-out must not be blockable — but it is never silent.
        //
        // Each table gets its own attempt on purpose: a failure deleting
        // snapshots must not skip the user-state rows, which are the more
        // sensitive half. (Written out rather than folded into a generic
        // helper because `#Predicate` over a protocol's key path is not
        // reliably convertible to a SwiftData query.)
        do {
            try modelContext.delete(model: CachedSnapshot.self, where: #Predicate { $0.scopeKey == scopeKey })
        } catch {
            Self.logger.error("[cache] purge left snapshot rows behind: \(Self.label(error), privacy: .public) — \(error)")
        }
        do {
            try modelContext.delete(model: CachedUserState.self, where: #Predicate { $0.scopeKey == scopeKey })
        } catch {
            Self.logger.error("[cache] purge left user-state rows behind: \(Self.label(error), privacy: .public) — \(error)")
        }
        save(after: "purge")
    }

    /// Forget everything cached for every scope
    public func purgeAll() {
        do {
            try modelContext.delete(model: CachedSnapshot.self)
        } catch {
            Self.logger.error("[cache] purgeAll left snapshot rows behind: \(Self.label(error), privacy: .public) — \(error)")
        }
        do {
            try modelContext.delete(model: CachedUserState.self)
        } catch {
            Self.logger.error(
                "[cache] purgeAll left user-state rows behind: \(Self.label(error), privacy: .public) — \(error)",
            )
        }
        save(after: "purgeAll")
    }

    /// Bound the one unbounded blob family: keep the newest `keep` item
    /// detail rows for the scope, drop the rest. Everything else in the
    /// store is a fixed, small key set.
    public func purgeStaleDetails(scope: CacheScope, keepingNewest keep: Int = 500) {
        let scopeKey = scope.storageKey
        let detailKind = CacheSnapshotKey.mediaDetailKind
        let descriptor = FetchDescriptor<CachedSnapshot>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.kind == detailKind },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)],
        )
        let rows = fetch(descriptor, during: "purgeStaleDetails")
        guard rows.count > keep else { return }
        Self.logger.info("[cache] pruning \(rows.count - keep) stale mediaDetail rows (keeping \(keep))")
        for row in rows.dropFirst(keep) {
            modelContext.delete(row)
        }
        save(after: "purgeStaleDetails")
    }
}

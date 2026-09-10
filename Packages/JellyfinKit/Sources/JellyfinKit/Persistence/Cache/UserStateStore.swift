import Foundation
import Observation

/// The single authority for watched / favorite / progress display state
/// (#193, absorbed into #24).
///
/// Before this store, four view models each held a private `MediaItem` copy
/// plus an optimistic override, and stale state crossed screen boundaries a
/// round trip late. Now every screen reads through `resolve` at render
/// time; server responses land once via `ingest`; and in-flight toggles are
/// pending operations that server ingests cannot clobber.
///
/// Rules the API encodes:
/// - `played` is only ever set from a server-reported value (an ingested
///   response or a server-acknowledged `mark*` confirmation). The server
///   owns its played threshold; `recordPosition` can never flip the flag.
/// - A failed toggle is reverted, never committed — an offline dismiss
///   cannot display a state the viewer didn't choose.
/// - The latest pending operation on a field wins; a superseded token's
///   confirm/revert is a no-op because the newer toggle owns the outcome.
///
/// `@MainActor` because every reader is a view model render path; the
/// SwiftData table is written behind it fire-and-forget (the in-memory map
/// is authoritative for the session, the table is the next cold start's
/// seed).
@MainActor
@Observable
public final class UserStateStore {
    /// Which user-data field a pending operation covers
    fileprivate enum Field: Hashable {
        case played
        case favorite
    }

    /// A claim on one field of one item while its server call is in
    /// flight. Hand it back through `confirm` or `revert` — exactly one.
    public struct PendingToken: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let itemID: String
        fileprivate let field: Field
        fileprivate let target: Bool
    }

    /// Committed state: the server's last word plus confirmed toggles
    private var states: [String: CachedUserStateValue] = [:]

    /// In-flight optimistic toggles; the value displayed while the server
    /// call runs, and the guard that keeps `ingest` from clobbering it
    private var pending: [String: [Field: (id: UUID, target: Bool)]] = [:]

    /// Bumped by every mutation that changes what a screen should show.
    /// Features observes this to decide a refresh is owed (#236 § 5.2). A
    /// counter, not a callback: this type lives in JellyfinKit and must not
    /// learn about the Features layer.
    public private(set) var mutationRevision = 0

    /// When a local playhead was recorded, per item. While a stamp stands,
    /// `ingest` will not let a response that predates the stopped report
    /// overwrite the value (#236 § 7).
    private var positionRecordedAt: [String: Date] = [:]

    /// Wakes observers when the guard lapses. Without it a page that
    /// painted the local Resume value inside the TTL keeps showing it after
    /// expiry — nothing else re-renders merely because time passed.
    private var positionExpiries: [String: Task<Void, Never>] = [:]

    /// Guards whose timer has fired. The stamp stays so `ingest` still
    /// recognises the item, but reads treat it as past the TTL from here on:
    /// clearing the stamp alone left the local ticks in `states` with
    /// nothing to override them, so the false Resume stood until the next
    /// ingest instead of ending at 30 s.
    private var expiredPositionGuards: Set<String> = []

    /// How long a locally recorded playhead outranks a differing server
    /// value. Bounded so a server that legitimately stores nothing — an item
    /// under `MinResumeDurationSeconds` — cannot leave a false Resume
    /// standing forever. See Task 0's probe.
    public static let positionGuardTTL: Duration = .seconds(30)

    /// How close a server position must be to the recorded one to count as
    /// the same playhead, in Jellyfin ticks (100ns). 5 seconds.
    public static let positionTolerance: Int64 = 50_000_000

    private var cache: ScopedCache?

    public init() {}

    // MARK: - Lifecycle

    /// Bind to a profile's cache and seed the overlay from its table, so a
    /// cold start's cached shelves render with table-fresh state.
    ///
    /// The seed fills gaps only: the connect flow's own fetches ingest
    /// before the session is published (and this runs), and that in-memory
    /// state is newer than anything the table holds.
    public func activate(cache: ScopedCache) async {
        self.cache = cache
        let seeded = await cache.store.allUserStates(scope: cache.scope)
        // A deactivate (sign-out) or a replacement activation may have
        // landed while the table read was on the store's actor. Their state
        // must win over this stale completion — merging it in would carry
        // one account's rows across the privacy boundary.
        guard !Task.isCancelled, self.cache?.scope == cache.scope else { return }
        states = seeded.merging(states) { _, memory in memory }
    }

    /// Sign-out / profile switch: drop everything. The privacy boundary —
    /// the next account must not see this one's watched state.
    public func deactivate() {
        cache = nil
        states = [:]
        pending = [:]
        positionRecordedAt.removeAll()
        expiredPositionGuards.removeAll()
        for task in positionExpiries.values {
            task.cancel()
        }
        positionExpiries.removeAll()
    }

    // MARK: - Reading

    /// The item as the viewer should see it right now: committed state
    /// overlaid, any pending toggle on top. Container unwatched counts stay
    /// the item's own — the table doesn't track them.
    public func resolve(_ item: MediaItem) -> MediaItem {
        let itemPending = pending[item.id]
        let committed = states[item.id]
        guard itemPending != nil || committed != nil else { return item }

        var value = committed ?? CachedUserStateValue(
            played: item.userData?.played ?? false,
            isFavorite: item.userData?.isFavorite ?? false,
            playbackPositionTicks: item.userData?.playbackPositionTicks,
            playCount: item.userData?.playCount,
            lastPlayedDate: item.userData?.lastPlayedDate,
        )
        // Past the TTL a recorded playhead stops being authoritative; fall
        // back to what the item itself carries (the
        // MinResumeDurationSeconds case). Any other guard state — active,
        // or never armed — leaves `value` alone: committed state already
        // reflects what `ingest`/`confirm` decided, including a played
        // toggle's deliberate nil.
        if let recordedAt = positionRecordedAt[item.id], positionGuardExpired(item.id, recordedAt: recordedAt) {
            value.playbackPositionTicks = item.userData?.playbackPositionTicks
        }
        if let played = itemPending?[.played]?.target {
            value.played = played
            // Mirrors MediaItem.settingPlayed: both transitions clear
            // resume progress on the server
            value.playbackPositionTicks = nil
        }
        if let favorite = itemPending?[.favorite]?.target {
            value.isFavorite = favorite
        }

        var copy = item
        copy.userData = UserData(
            playbackPositionTicks: value.playbackPositionTicks,
            playCount: value.playCount,
            isFavorite: value.isFavorite,
            played: value.played,
            lastPlayedDate: value.lastPlayedDate,
            // A played container has nothing unwatched left — mirroring
            // MediaItem.settingPlayed, so a series marked watched can't
            // render a played badge next to a stale unwatched count
            unplayedItemCount: value.played ? 0 : item.userData?.unplayedItemCount,
        )
        return copy
    }

    public func resolving(_ items: [MediaItem]) -> [MediaItem] {
        items.map(resolve)
    }

    /// Favorite state for ids that aren't `MediaItem`s (persons are items
    /// on the server, but the facade models them separately)
    public func isFavorite(itemID: String, fallback: Bool) -> Bool {
        if let target = pending[itemID]?[.favorite]?.target {
            return target
        }
        return states[itemID]?.isFavorite ?? fallback
    }

    // MARK: - Server truth

    /// Record what a server response said about these items. A field with a
    /// pending toggle keeps its committed value — the response predates the
    /// mutation in flight, and the toggle's confirm/revert owns that field.
    public func ingest(serverItems: [MediaItem]) {
        for item in serverItems {
            guard let data = item.userData, !item.id.isEmpty else { continue }
            var value = CachedUserStateValue(
                played: data.played,
                isFavorite: data.isFavorite,
                playbackPositionTicks: data.playbackPositionTicks,
                playCount: data.playCount,
                lastPlayedDate: data.lastPlayedDate,
            )
            if let fields = pending[item.id], let current = states[item.id] {
                if fields[.played] != nil {
                    value.played = current.played
                    value.playbackPositionTicks = current.playbackPositionTicks
                }
                if fields[.favorite] != nil {
                    value.isFavorite = current.isFavorite
                }
            }
            // A locally recorded playhead outranks a response that predates
            // the stopped report (#236 § 7). Four outcomes, in this order.
            if let recordedAt = positionRecordedAt[item.id],
               let local = states[item.id]?.playbackPositionTicks
            {
                if data.played {
                    // The server's watched verdict wins and clears the
                    // playhead, mirroring `confirm`'s played branch.
                    value.playbackPositionTicks = nil
                    liftPositionGuard(for: item.id)
                } else if abs((data.playbackPositionTicks ?? 0) - local) <= Self.positionTolerance {
                    // The round trip closed: the server is reporting our own
                    // value back. Accept it and lift the guard.
                    liftPositionGuard(for: item.id)
                } else if !positionGuardExpired(item.id, recordedAt: recordedAt) {
                    value.playbackPositionTicks = local
                } else {
                    // Expired: stop shadowing a server that holds something
                    // else, or nothing.
                    liftPositionGuard(for: item.id)
                }
            }
            states[item.id] = value
        }
        guard let cache else { return }
        let items = serverItems
        Task {
            await cache.store.ingestServerUserData(scope: cache.scope, items: items)
        }
    }

    /// Seed the favorite flag from a server response that isn't a
    /// `MediaItem` (a person fetch); pending-guarded like `ingest`
    public func ingestServerFavorite(itemID: String, isFavorite serverValue: Bool) {
        guard pending[itemID]?[.favorite] == nil else { return }
        var value = states[itemID] ?? CachedUserStateValue()
        value.isFavorite = serverValue
        states[itemID] = value
        persist(itemID: itemID, value: value)
    }

    // MARK: - Toggles

    public func beginPlayedToggle(itemID: String, target: Bool) -> PendingToken {
        begin(itemID: itemID, field: .played, target: target)
    }

    public func beginFavoriteToggle(itemID: String, target: Bool) -> PendingToken {
        begin(itemID: itemID, field: .favorite, target: target)
    }

    /// The server acknowledged the token's mutation: commit it. A
    /// superseded token no-ops — the newer toggle owns the field.
    public func confirm(_ token: PendingToken) {
        guard clearPending(token) else { return }
        var value = states[token.itemID] ?? CachedUserStateValue()
        switch token.field {
        case .played:
            value.played = token.target
            value.playbackPositionTicks = nil
        case .favorite:
            value.isFavorite = token.target
        }
        states[token.itemID] = value
        persist(itemID: token.itemID, value: value)
        // A confirmed played toggle already cleared the position; drop the
        // guard with it so a later server read is not shadowed by a
        // playhead that no longer exists.
        if token.field == .played {
            liftPositionGuard(for: token.itemID)
        }
        mutationRevision &+= 1
    }

    /// The server call failed: withdraw the pending display. Committed
    /// state was never touched, so the viewer sees the pre-toggle truth.
    public func revert(_ token: PendingToken) {
        _ = clearPending(token)
    }

    // MARK: - Progress

    /// Track the playhead so shelves show a correct resume bar the moment
    /// the player dismisses. Deliberately cannot flip `played`: the server
    /// owns its watched threshold, and a client guess would confidently
    /// mislabel a 92% stop (#193).
    ///
    /// - Parameter now: injectable only so the guard's TTL is testable
    ///   without sleeping.
    public func recordPosition(itemID: String, ticks: Int64, now: Date = .now) {
        var value = states[itemID] ?? CachedUserStateValue()
        value.playbackPositionTicks = ticks
        states[itemID] = value
        positionRecordedAt[itemID] = now
        expiredPositionGuards.remove(itemID)
        mutationRevision &+= 1
        persist(itemID: itemID, value: value)
        scheduleExpiry(for: itemID, recordedAt: now)
    }

    // MARK: - Internals

    /// Clears the local playhead guard for `itemID`, cancelling its
    /// scheduled expiry so a later firing can't clear a guard that ingest
    /// already resolved.
    private func liftPositionGuard(for itemID: String) {
        positionRecordedAt[itemID] = nil
        expiredPositionGuards.remove(itemID)
        positionExpiries[itemID]?.cancel()
        positionExpiries[itemID] = nil
    }

    /// Wakes observers when the guard lapses. Without it the read-time
    /// check above is never re-run for a page that is simply sitting there.
    private func scheduleExpiry(for itemID: String, recordedAt: Date) {
        positionExpiries[itemID]?.cancel()
        positionExpiries[itemID] = Task { [weak self] in
            try? await Task.sleep(for: Self.positionGuardTTL)
            guard !Task.isCancelled, let self else { return }
            // Only if this is still the stamp we scheduled for: a newer
            // `recordPosition` must not be cleared by an older expiry.
            guard positionRecordedAt[itemID] == recordedAt else { return }
            expirePositionGuard(for: itemID)
        }
    }

    /// What the timer does when it fires. Marks the guard expired rather
    /// than clearing it, so every read falls back to the item's own value
    /// until an ingest lifts the guard properly, and wakes observers so a
    /// page sitting on the local playhead re-renders without it.
    func expirePositionGuard(for itemID: String) {
        guard positionRecordedAt[itemID] != nil else { return }
        expiredPositionGuards.insert(itemID)
        positionExpiries[itemID] = nil
        mutationRevision &+= 1
    }

    private func positionGuardExpired(_ itemID: String, recordedAt: Date) -> Bool {
        expiredPositionGuards.contains(itemID)
            || Date.now.timeIntervalSince(recordedAt) >= Self.positionGuardTTL.timeIntervalValue
    }

    private func begin(itemID: String, field: Field, target: Bool) -> PendingToken {
        let token = PendingToken(id: UUID(), itemID: itemID, field: field, target: target)
        pending[itemID, default: [:]][field] = (token.id, target)
        return token
    }

    /// Remove the token's pending entry; false when a newer toggle on the
    /// same field superseded it
    private func clearPending(_ token: PendingToken) -> Bool {
        guard pending[token.itemID]?[token.field]?.id == token.id else { return false }
        pending[token.itemID]?[token.field] = nil
        if pending[token.itemID]?.isEmpty == true {
            pending[token.itemID] = nil
        }
        return true
    }

    private func persist(itemID: String, value: CachedUserStateValue) {
        guard let cache else { return }
        Task {
            await cache.store.setUserState(scope: cache.scope, itemID: itemID) { $0 = value }
        }
    }
}

private extension Duration {
    /// `Duration` has no `TimeInterval` bridge; components are
    /// (seconds, attoseconds).
    var timeIntervalValue: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}

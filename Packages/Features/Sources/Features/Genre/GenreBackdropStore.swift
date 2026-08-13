import Foundation
import JellyfinKit

/// Which genre card a remembered backdrop belongs to.
///
/// `libraryId` is optional deliberately. Home's genre shelves are always
/// scoped to a library, but a genre shelf on a media detail page (#108) has no
/// library to scope to — keying on `String?` lets that case store alongside
/// these without a format migration.
struct GenreBackdropKey: Hashable, Sendable {
    var libraryId: String?
    var genre: String

    /// Flattened form used as the dictionary key in the cached map. The unit
    /// separator can't occur in a library id or a genre name, so a real genre
    /// like "Action/Adventure" can't be confused with a library boundary.
    var storageKey: String {
        "\(libraryId ?? "")\u{1F}\(genre)"
    }
}

/// A genre card's remembered face: the artwork it borrows, plus what the card
/// needs to redraw it and to cycle cheaply.
struct GenreBackdropSelection: Codable, Equatable, Sendable {
    /// The item that owns the image. Not necessarily the item that matched the
    /// genre — `backdropSlot(for:)` falls back to an ancestor's backdrop.
    var itemId: String
    /// `ImageType`'s raw value; the enum has no `Codable` conformance. A value
    /// this build can't map back re-rolls, same as any other unusable entry.
    var imageTypeRawValue: String
    var blurHash: String?
    /// How many items the genre had when this was chosen, so the first cycle
    /// after a relaunch can still pick a random offset without spending a
    /// request to learn the pool size. A stale count just lands on an empty
    /// page, which falls back to a re-roll of the first page.
    var poolCount: Int?

    var imageType: ImageType? {
        ImageType(rawValue: imageTypeRawValue)
    }
}

/// Remembers which item's backdrop stands in for each genre card, so returning
/// to a genre shelf costs no request and shows the same face it showed before.
///
/// Backed by the metadata cache (#207, following #24), which is what makes the
/// picks *per profile*: `UserDefaults` is not scoped, so before this the picks
/// survived sign-out and would have rendered one account's artwork on another
/// account's cards once saved profiles (#192) land. Keyed by `(serverURL,
/// userID)` now, and purged with the rest of the scope on sign-out.
///
/// Synchronous readers over an asynchronously hydrated mirror, copying
/// `UserStateStore`: `selection(for:)` is called from a card's render path, so
/// it cannot await the store's actor. `activate(cache:)` seeds the mirror,
/// `deactivate()` drops it, and `AppSession` owns both.
@MainActor
final class GenreBackdropStore {
    /// The key the pre-cache build wrote to. Dead storage now: the picks are
    /// re-rollable decoration, so #207 dropped them rather than adopting them
    /// into the cache.
    private static let legacyDefaultsKey = "genreBackdropSelections"

    /// Authoritative for reads; the cached blob is the next cold start's seed
    private var selections: [String: GenreBackdropSelection] = [:]

    private var cache: ScopedCache?

    init() {
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
    }

    // MARK: - Lifecycle

    /// Bind to a profile's cache and seed the mirror from it, so a card that
    /// mounts after a cold launch wears the face it had last time.
    func activate(cache: ScopedCache) async {
        self.cache = cache
        let stored = await cache.read([String: GenreBackdropSelection].self, key: .genreBackdrops) ?? [:]
        // A deactivate (sign-out) or a replacement activation may have landed
        // while the read was on the store's actor. Their state must win over
        // this stale completion — merging it in would carry one account's
        // picks across the privacy boundary.
        guard !Task.isCancelled, self.cache?.scope == cache.scope else { return }
        // Anything already in memory was rolled before hydration landed, and
        // is newer than the blob.
        let raced = !selections.isEmpty
        selections = stored.merging(selections) { _, memory in memory }
        // Unlike `UserStateStore`, which persists one item at a time, this
        // store writes the whole map — so a pick rolled during the hydration
        // window has already written a blob that omits every stored entry.
        // Write the merged map back rather than leaving disk short.
        if raced {
            persist()
        }
    }

    /// Sign-out / profile switch: drop everything. Clearing the mirror is the
    /// privacy boundary — purging the scope on disk while memory still holds
    /// the previous account's picks would leak them for the rest of the launch.
    func deactivate() {
        cache = nil
        selections = [:]
    }

    // MARK: - Reading

    func selection(for key: GenreBackdropKey) -> GenreBackdropSelection? {
        selections[key.storageKey]
    }

    /// Store a choice, or clear it with `nil`. Writes the whole map — it is
    /// tens of short strings, so there's nothing to gain from a finer write.
    func setSelection(_ selection: GenreBackdropSelection?, for key: GenreBackdropKey) {
        selections[key.storageKey] = selection
        persist()
    }

    /// Fire-and-forget, like `UserStateStore`: the mirror is authoritative for
    /// the session, so a write that loses a race is a re-roll next launch, not
    /// an error a card could act on.
    private func persist() {
        guard let cache else { return }
        let snapshot = selections
        Task {
            await cache.write(snapshot, key: .genreBackdrops)
        }
    }
}

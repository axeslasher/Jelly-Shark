import Foundation
import JellyfinKit
import Observation

/// Chooses — and remembers — the backdrop that stands in for one library card
/// on the visionOS Libraries grid (#138).
///
/// A library does have artwork of its own (Jellyfin's collection-folder Primary
/// image), and `JellyfinClientProtocol.imageURL(for:)` would hand it over for
/// free. The card deliberately does not use it: those images are collages with
/// the library's name baked into the pixels, which fights the card's own label.
/// So a library borrows a member item's backdrop instead, exactly the way a
/// genre card borrows one.
///
/// Sibling to `GenreCardViewModel`, not a reuse of it: the two answer the same
/// question about different subjects, and the genre model's `genre` is
/// load-bearing all the way down to its cache key. They share what actually is
/// shared — `GenreBackdropStore`, `GenreBackdropSelection`, and
/// `backdropSlot(for:)` — and are keyed apart by `GenreBackdropKey.Subject`, so
/// a library's remembered face can never collide with a genre's. If a third
/// subject ever wants the same treatment, that is the moment to generalize the
/// two into one model rather than now.
///
/// No cycle/shuffle gesture: a genre card offers one because a genre is an
/// abstraction with no canonical face, while a library grid is a navigation
/// surface where a card changing its picture under a long press is noise.
@Observable
@MainActor
final class LibraryCardViewModel {
    /// Sample page size. Small on purpose: the card needs one item with
    /// artwork, not a catalogue.
    static let pageSize = 12

    /// Matches `GenreCardViewModel`'s width so a library card and a genre card
    /// that land on the same item share a `URLCache` entry and a decoded-image
    /// cache entry rather than fetching the same picture twice.
    private static let backdropMaxWidth = 1920

    private(set) var selection: GenreBackdropSelection?

    /// Latches once the backdrop has settled, so the card's `.task` re-firing
    /// on reappearance doesn't re-sample — the grid must not reshuffle every
    /// time the viewer comes back to it. Only a *settled* load latches: a
    /// failed fetch leaves this false so the next appearance retries.
    private var didLoad = false

    /// One repair per realization. A selection whose artwork 404s re-samples
    /// once; if the replacement also fails to render (an unreachable server,
    /// say) the card holds still rather than spinning in a fetch loop.
    private var didRepair = false

    /// Handed over in the card's `.task` rather than at init: the store is
    /// scoped to the signed-in profile and lives on `AppSession`, which a
    /// `@State` view model cannot read from the environment when it is built.
    /// Nil until then, so an unattached card is merely always-cold.
    private var store: GenreBackdropStore?

    init() {}

    func attach(store: GenreBackdropStore) {
        self.store = store
    }

    /// The chosen artwork's URL, rebuilt against the session's current server
    /// address rather than persisted whole — so reconnecting to the same
    /// server at a different address doesn't invalidate every card.
    func backdropURL(client: (any JellyfinClientProtocol)?) -> URL? {
        guard let client, let selection, let imageType = selection.imageType else { return nil }
        return client.getImageURL(
            itemId: selection.itemId,
            imageType: imageType,
            maxWidth: Self.backdropMaxWidth,
            maxHeight: nil,
        )
    }

    var blurHash: String? {
        selection?.blurHash
    }

    // MARK: - Loading

    /// Adopt the remembered choice, or make one if this library has none.
    ///
    /// The remembered choice is taken at face value — validating it would cost
    /// the request this whole mechanism exists to avoid. It's repaired if it
    /// turns out not to render (`backdropUnavailable`).
    ///
    /// Every card owns one of these, so the grid's fetches are independent: a
    /// library whose sample request fails leaves that one card on its themed
    /// wash and says nothing about the others.
    func load(client: (any JellyfinClientProtocol)?, library: Library) async {
        guard !didLoad else { return }

        // An entry whose image type this build can't map back is unusable, so
        // it falls through to a cold sample rather than rendering nothing.
        if let remembered = store?.selection(for: Self.key(library: library)),
           remembered.imageType != nil
        {
            selection = remembered
            didLoad = true
            return
        }

        guard let client else { return }
        didLoad = await sample(client: client, library: library)
    }

    /// The remembered artwork didn't render — the item was deleted, or its
    /// images were. Re-sample exactly as if the card were cold, so a stale
    /// entry costs one fetch and never renders broken.
    ///
    /// The old choice is only given up once a sample actually settles: the same
    /// nil image reports a server that's merely unreachable, and an offline
    /// launch must not cost every card the face it had.
    func backdropUnavailable(client: (any JellyfinClientProtocol)?, library: Library) async {
        guard !didRepair, let stale = selection, let client else { return }
        didRepair = true

        guard await sample(client: client, library: library) else { return }
        guard selection?.itemId == stale.itemId else { return }

        // The sample settled on the same broken face, or on nothing at all —
        // the library has genuinely lost its artwork, so drop to a wash-only
        // card.
        selection = nil
        store?.setSelection(nil, for: Self.key(library: library))
    }

    // MARK: - Sampling

    /// Fetch one page from the library and adopt a random item's backdrop,
    /// remembering the choice. Returns whether the sample settled: true on
    /// success or on a genuinely artless library (wash-only is final), false
    /// when the fetch failed and is worth retrying. The `try?` stays — the
    /// backdrop is pure cosmetic enrichment, so a failure never surfaces an
    /// error, it just leaves the card wearing its themed wash.
    ///
    /// Internal rather than private so tests can drive it directly.
    func sample(client: any JellyfinClientProtocol, library: Library) async -> Bool {
        // The same query the card's destination grid will run, so the sample is
        // drawn from exactly the pool the card opens — asked for its
        // `itemTypes` rather than restating the movie/series rule here.
        let query = LibraryQuery(library: library)
        guard let page = try? await client.getLibraryItems(
            libraryId: library.id,
            itemTypes: query.itemTypes,
            query: query,
            limit: Self.pageSize,
            // The first page, always: a random offset needs a pool size, and
            // learning one costs the request this is trying to be. The choice
            // is remembered, so a library is sampled once per profile anyway.
            startIndex: 0,
        ) else { return false }

        let candidates = page.items.compactMap { item in
            client.backdropSlot(for: item).map { (item: item, slot: $0) }
        }
        // Prefer anything but the face already on screen. Only the repair path
        // can arrive here with one, and it reads "the sample came back with the
        // same item" as proof the library has nothing else to offer — which a
        // random re-pick of a healthy pool would fake.
        let fresh = candidates.filter { $0.slot.itemId != selection?.itemId }
        guard let chosen = (fresh.isEmpty ? candidates : fresh).randomElement() else {
            // A genuinely artless library stays a wash-only card. Nothing worth
            // remembering: the library gaining artwork later should show it.
            return true
        }

        let chosenSelection = GenreBackdropSelection(
            itemId: chosen.slot.itemId,
            imageTypeRawValue: chosen.slot.imageType.rawValue,
            blurHash: chosen.item.backdropBlurHash,
            poolCount: page.totalRecordCount,
        )
        selection = chosenSelection
        store?.setSelection(chosenSelection, for: Self.key(library: library))
        return true
    }

    private static func key(library: Library) -> GenreBackdropKey {
        .library(id: library.id)
    }
}

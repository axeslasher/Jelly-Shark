// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import JellyfinKit
import Observation

/// Chooses — and remembers — the backdrop that stands in for one genre.
///
/// A genre has no artwork of its own, so a card borrows a member's. The choice
/// is persisted (`GenreBackdropStore`), which inverts the original behaviour:
/// stable by default, random on request. A warm card costs no request at all;
/// only a cold card, a long-press cycle, or a selection that no longer renders
/// goes to the server.
@Observable
@MainActor
final class GenreCardViewModel {
    /// Sample page size. Small on purpose: the card needs one item with
    /// artwork, not a catalogue.
    static let pageSize = 12

    /// Matches `backdropURL(for:)`'s default so a remembered choice and a
    /// freshly rolled one produce the identical URL — same `URLCache` entry,
    /// same decoded-image cache entry.
    private static let backdropMaxWidth = 1920

    private(set) var selection: GenreBackdropSelection?

    /// Latches once the backdrop has settled, so the card's `.task` re-firing
    /// on reappearance doesn't re-roll. Only a *settled* load latches: a
    /// failed fetch leaves this false so scrolling the card back into view
    /// retries.
    private var didLoad = false

    /// One repair per realization. A selection whose artwork 404s re-rolls
    /// once; if the replacement also fails to render (an unreachable server,
    /// say) the card holds still rather than spinning in a fetch loop.
    private var didRepair = false

    /// Guards against a second long-press landing while the first is in
    /// flight.
    private var isCycling = false

    private let store: GenreBackdropStore

    init(store: GenreBackdropStore = .shared) {
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

    /// Adopt the remembered choice, or make one if this genre has none.
    ///
    /// The remembered choice is taken at face value — validating it would cost
    /// the request this whole mechanism exists to avoid. It's repaired if it
    /// turns out not to render (`backdropUnavailable`).
    func load(client: (any JellyfinClientProtocol)?, library: Library, genre: String) async {
        guard !didLoad else { return }

        // An entry whose image type this build can't map back is unusable, so
        // it falls through to a cold roll rather than rendering nothing.
        if let remembered = store.selection(for: Self.key(library: library, genre: genre)),
           remembered.imageType != nil
        {
            selection = remembered
            didLoad = true
            return
        }

        guard let client else { return }
        didLoad = await roll(client: client, library: library, genre: genre, startIndex: 0)
    }

    /// Roll a different backdrop on demand — the long-press action.
    ///
    /// Fetches a fresh page at a random offset rather than re-rolling within
    /// the twelve items already in hand: that pool exhausts fast and starts
    /// repeating, which defeats the gesture. One request per press, and the
    /// press is deliberate and occasional, so it's on no hot path.
    func cycle(client: (any JellyfinClientProtocol)?, library: Library, genre: String) async {
        guard let client, !isCycling else { return }
        isCycling = true
        defer { isCycling = false }

        let startIndex = Self.randomStartIndex(poolCount: selection?.poolCount, pageSize: Self.pageSize)
        if await roll(client: client, library: library, genre: genre, startIndex: startIndex) {
            didLoad = true
        }
    }

    /// The remembered artwork didn't render — the item was deleted, or its
    /// images were. Re-roll exactly as if the card were cold, so a stale entry
    /// costs one fetch and never renders broken.
    ///
    /// The old choice is only given up once a roll actually settles: the same
    /// nil image reports a server that's merely unreachable, and an offline
    /// launch must not cost every card the face it had.
    func backdropUnavailable(client: (any JellyfinClientProtocol)?, library: Library, genre: String) async {
        guard !didRepair, let stale = selection, let client else { return }
        didRepair = true

        guard await roll(client: client, library: library, genre: genre, startIndex: 0) else { return }
        guard selection?.itemId == stale.itemId else { return }

        // The roll settled on the same broken face, or on nothing at all — the
        // genre has genuinely lost its artwork, so drop to a mesh-only card.
        selection = nil
        store.setSelection(nil, for: Self.key(library: library, genre: genre))
    }

    // MARK: - Rolling

    /// Fetch a sample page and adopt a random item's backdrop, remembering the
    /// choice. Returns whether the roll settled: true on success or on a
    /// genuinely artless genre (mesh-only is final), false when the fetch
    /// failed and is worth retrying. The `try?` stays — the backdrop is pure
    /// cosmetic enrichment, so a failure never surfaces an error.
    ///
    /// Internal rather than private so tests can exercise a specific page
    /// boundary without having to steer the random offset.
    func roll(
        client: any JellyfinClientProtocol,
        library: Library,
        genre: String,
        startIndex: Int,
    ) async -> Bool {
        guard let page = try? await client.getLibraryItems(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes,
            query: LibraryQuery(genres: [genre]),
            limit: Self.pageSize,
            startIndex: startIndex,
        ) else { return false }

        // An offset derived from a remembered pool count can overshoot a genre
        // that has since shrunk; an empty page is the server saying so, so
        // start over from the top rather than leaving the card bare.
        if page.items.isEmpty, startIndex > 0 {
            return await roll(client: client, library: library, genre: genre, startIndex: 0)
        }

        let candidates = page.items.compactMap { item in
            client.backdropSlot(for: item).map { (item: item, slot: $0) }
        }
        // Prefer anything but the face already on screen, so a press always
        // looks like it did something; a one-item pool re-picks it.
        let fresh = candidates.filter { $0.slot.itemId != selection?.itemId }
        guard let chosen = (fresh.isEmpty ? candidates : fresh).randomElement() else {
            // A genuinely artless genre stays a mesh-only card. Nothing worth
            // remembering: the genre gaining artwork later should show it.
            return true
        }

        let chosenSelection = GenreBackdropSelection(
            itemId: chosen.slot.itemId,
            imageTypeRawValue: chosen.slot.imageType.rawValue,
            blurHash: chosen.item.backdropBlurHash,
            poolCount: page.totalRecordCount,
        )
        selection = chosenSelection
        store.setSelection(chosenSelection, for: Self.key(library: library, genre: genre))
        return true
    }

    /// Where a cycling fetch starts. A pool no bigger than one page has no
    /// meaningful offset to pick, so cycling degrades to a re-roll of the same
    /// items — deliberate, not accidental. An unknown pool count does the
    /// same, and the count that fetch reports makes the next press a real
    /// offset.
    static func randomStartIndex(poolCount: Int?, pageSize: Int) -> Int {
        guard let poolCount, poolCount > pageSize else { return 0 }
        return Int.random(in: 0 ... (poolCount - pageSize))
    }

    private static func key(library: Library, genre: String) -> GenreBackdropKey {
        GenreBackdropKey(libraryId: library.id, genre: genre)
    }
}

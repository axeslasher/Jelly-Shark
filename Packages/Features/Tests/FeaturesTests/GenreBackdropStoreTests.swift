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

@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("GenreBackdropStore")
@MainActor
struct GenreBackdropStoreTests {
    /// A scratch defaults suite per test, so nothing leaks into the standard
    /// domain (or between tests).
    private func makeDefaults() -> UserDefaults {
        let suiteName = "GenreBackdropStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func selection(_ itemId: String) -> GenreBackdropSelection {
        GenreBackdropSelection(
            itemId: itemId,
            imageTypeRawValue: ImageType.backdrop.rawValue,
            blurHash: "hash",
            poolCount: 40,
        )
    }

    @Test("Nothing is remembered before anything is chosen")
    func emptyByDefault() {
        let store = GenreBackdropStore(defaults: makeDefaults())
        #expect(store.selection(for: GenreBackdropKey(libraryId: "movies", genre: "Horror")) == nil)
    }

    @Test("A choice survives a relaunch")
    func persistsAcrossInstances() {
        // The whole point of the store: `@State` dies with the view, so only a
        // trip through UserDefaults keeps a genre's face stable across launches.
        let defaults = makeDefaults()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

        GenreBackdropStore(defaults: defaults).setSelection(selection("item-1"), for: key)

        #expect(GenreBackdropStore(defaults: defaults).selection(for: key) == selection("item-1"))
    }

    @Test("Clearing a choice removes it, including from disk")
    func clearing() {
        let defaults = makeDefaults()
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")

        let store = GenreBackdropStore(defaults: defaults)
        store.setSelection(selection("item-1"), for: key)
        store.setSelection(nil, for: key)

        #expect(store.selection(for: key) == nil)
        #expect(GenreBackdropStore(defaults: defaults).selection(for: key) == nil)
    }

    @Test("The same genre in two libraries keeps two faces")
    func scopedPerLibrary() {
        let store = GenreBackdropStore(defaults: makeDefaults())
        let movies = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        let fourK = GenreBackdropKey(libraryId: "4k-movies", genre: "Horror")

        store.setSelection(selection("item-1"), for: movies)
        store.setSelection(selection("item-2"), for: fourK)

        #expect(store.selection(for: movies)?.itemId == "item-1")
        #expect(store.selection(for: fourK)?.itemId == "item-2")
    }

    @Test("A genre name containing a separator can't collide across libraries")
    func separatorInGenreName() {
        // "Action/Adventure" is a real Jellyfin genre, so the key can't be
        // joined on any character a genre name might contain.
        let store = GenreBackdropStore(defaults: makeDefaults())
        let first = GenreBackdropKey(libraryId: "a", genre: "b/c")
        let second = GenreBackdropKey(libraryId: "a/b", genre: "c")

        store.setSelection(selection("item-1"), for: first)
        store.setSelection(selection("item-2"), for: second)

        #expect(store.selection(for: first)?.itemId == "item-1")
        #expect(store.selection(for: second)?.itemId == "item-2")
    }

    @Test("A library-less key stores alongside a library-scoped one")
    func libraryLessKey() {
        // #108 mounts a genre shelf on a media detail page, where there is no
        // library to scope to. The key shape has to hold that without a
        // stored-format migration.
        let defaults = makeDefaults()
        let scoped = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        let unscoped = GenreBackdropKey(libraryId: nil, genre: "Horror")

        let store = GenreBackdropStore(defaults: defaults)
        store.setSelection(selection("item-1"), for: scoped)
        store.setSelection(selection("item-2"), for: unscoped)

        let reloaded = GenreBackdropStore(defaults: defaults)
        #expect(reloaded.selection(for: scoped)?.itemId == "item-1")
        #expect(reloaded.selection(for: unscoped)?.itemId == "item-2")
    }

    @Test("An unreadable payload reads as empty rather than throwing")
    func corruptPayload() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "genreBackdropSelections")

        let store = GenreBackdropStore(defaults: defaults)
        #expect(store.selection(for: GenreBackdropKey(libraryId: "movies", genre: "Horror")) == nil)

        // …and writing over it still works, so the app self-heals.
        let key = GenreBackdropKey(libraryId: "movies", genre: "Horror")
        store.setSelection(selection("item-1"), for: key)
        #expect(GenreBackdropStore(defaults: defaults).selection(for: key)?.itemId == "item-1")
    }
}

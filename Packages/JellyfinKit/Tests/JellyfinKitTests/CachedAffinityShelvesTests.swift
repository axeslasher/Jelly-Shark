import Foundation
@testable import JellyfinKit
import Testing

@Suite("CachedAffinityShelves")
struct CachedAffinityShelvesTests {
    private let scope = CacheScope(serverURL: URL(string: "https://example.com")!, userID: "u1")

    private func payload() -> CachedAffinityShelves {
        CachedAffinityShelves(
            fingerprint: "abc123",
            stamp: AffinityLibraryStamp(libraryIDs: ["l1"], librarySize: 900),
            stampProbedAt: Date(timeIntervalSince1970: 1_767_225_600),
            denominators: [.genre("Horror"): 40, .person("p1"): 6],
            denominatorsProbedAt: Date(timeIntervalSince1970: 1_767_225_600),
            shelves: [
                CachedAffinityShelf(
                    descriptor: AffinityShelfDescriptor(
                        kind: .bucket(.genreDecade("Horror", 1980)),
                        title: "More horror from the 1980s",
                        score: 4.2,
                        personName: nil,
                    ),
                    items: [MediaItem(id: "m1", name: "M1", type: .movie)],
                ),
            ],
        )
    }

    @Test func theKeyIsItsOwnStorageSlot() {
        #expect(CacheSnapshotKey.affinityShelves.storageKey == "affinityShelves")
        #expect(CacheSnapshotKey.affinityShelves.kind == "affinityShelves")
    }

    /// Adding a case must not change an existing storageKey — that is what
    /// keeps schemaVersion at 2 and skips the wipe.
    @Test func existingStorageKeysAreUnchanged() {
        #expect(CacheSnapshotKey.homeSnapshot.storageKey == "home")
        #expect(CacheSnapshotKey.genreBackdrops.storageKey == "genreBackdrops")
        #expect(MediaCacheStore.schemaVersion == 2)
    }

    @Test func thePayloadRoundTripsThroughTheStore() async {
        let store = MediaCacheStore.makeInMemory()
        await store.write(payload(), scope: scope, key: .affinityShelves)
        let read = await store.read(CachedAffinityShelves.self, scope: scope, key: .affinityShelves)
        #expect(read == payload())
    }

    /// #324: a row written before `rulesVersion` existed must decode as out
    /// of date, not fail to decode or pass as current.
    @Test func aRowWithoutARulesVersionDecodesAsVersionZero() throws {
        let encoded = try JSONEncoder().encode(payload())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rulesVersion")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CachedAffinityShelves.self, from: legacy)
        #expect(decoded.rulesVersion == 0)
        #expect(decoded.shelves == payload().shelves)
        #expect(payload().rulesVersion == AffinityTuning.rulesVersion)
    }

    @Test func bucketKeyedDenominatorsSurviveTheRoundTrip() async {
        let store = MediaCacheStore.makeInMemory()
        await store.write(payload(), scope: scope, key: .affinityShelves)
        let read = await store.read(CachedAffinityShelves.self, scope: scope, key: .affinityShelves)
        #expect(read?.denominators[.genre("Horror")] == 40)
        #expect(read?.denominators[.person("p1")] == 6)
    }
}

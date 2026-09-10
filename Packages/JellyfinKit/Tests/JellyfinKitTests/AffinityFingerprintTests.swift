import Foundation
@testable import JellyfinKit
import Testing

@Suite("AffinityFingerprint")
struct AffinityFingerprintTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)
    private let stamp = AffinityLibraryStamp(libraryIDs: ["lib-a", "lib-b"], librarySize: 1000)

    private func signal(_ id: String, played: Date? = nil, favorite: Bool = false) -> AffinitySignal {
        AffinitySignal(
            sourceID: id, name: id, buckets: [.genre("Horror")],
            personNames: [:], lastPlayed: played, isFavorite: favorite,
        )
    }

    private func make(
        _ signals: [AffinitySignal],
        people: [Person] = [],
        now: Date? = nil,
        stamp: AffinityLibraryStamp? = nil,
    ) -> String {
        AffinityFingerprint.make(
            signals: signals,
            favoritedPeople: people,
            now: now ?? self.now,
            stamp: stamp ?? self.stamp,
        )
    }

    /// Swift's Hasher is randomly seeded per process; this must not be.
    @Test func identicalInputsProduceIdenticalDigests() {
        #expect(make([signal("s1", played: now)]) == make([signal("s1", played: now)]))
    }

    @Test func inputOrderDoesNotChangeTheDigest() {
        let a = signal("a", played: now)
        let b = signal("b", played: now)
        #expect(make([a, b]) == make([b, a]))
    }

    @Test func aNewPlayDateChangesTheDigest() {
        #expect(make([signal("s1", played: now)]) != make([signal("s1", played: now.addingTimeInterval(3600))]))
    }

    @Test func aNewFavoriteChangesTheDigest() {
        #expect(make([signal("s1", played: now)]) != make([signal("s1", played: now, favorite: true)]))
    }

    @Test func aNewFavoritedPersonChangesTheDigest() {
        #expect(make([signal("s1")]) != make([signal("s1")], people: [Person(id: "p1", name: "P")]))
    }

    /// Recency decays with wall-clock time, so a history-only hash would
    /// freeze the shelf set forever on a library nobody adds to.
    @Test func theNextDayChangesTheDigest() {
        #expect(make([signal("s1", played: now)]) != make([signal("s1", played: now)], now: now.addingTimeInterval(86400)))
    }

    @Test func theSameDayDoesNotChangeTheDigest() {
        #expect(make([signal("s1", played: now)]) == make([signal("s1", played: now)], now: now.addingTimeInterval(60)))
    }

    @Test func aChangedLibrarySizeChangesTheDigest() {
        let grown = AffinityLibraryStamp(libraryIDs: ["lib-a", "lib-b"], librarySize: 1001)
        #expect(make([signal("s1")]) != make([signal("s1")], stamp: grown))
    }

    @Test func aChangedLibrarySetChangesTheDigest() {
        let added = AffinityLibraryStamp(libraryIDs: ["lib-a", "lib-b", "lib-c"], librarySize: 1000)
        #expect(make([signal("s1")]) != make([signal("s1")], stamp: added))
    }
}

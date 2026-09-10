import Foundation
@testable import JellyfinKit
import Testing

@Suite("AffinitySelection")
struct AffinitySelectionTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    private func signal(
        _ id: String,
        buckets: Set<AffinityBucket>,
        played: Date? = nil,
        favorite: Bool = false,
        names: [String: String] = [:],
    ) -> AffinitySignal {
        AffinitySignal(
            sourceID: id, name: "Title \(id)", buckets: buckets,
            personNames: names, lastPlayed: played, isFavorite: favorite,
        )
    }

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .movie)
    }

    @Test func noQualifyingBucketMeansNoShelvesAtAllIncludingSimilar() {
        let signals = [signal("s1", buckets: [.genre("Horror")], played: now)]
        let scores = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let shelves = AffinitySelection.select(signals: signals, scores: scores, qualifying: [])
        #expect(shelves.isEmpty)
    }

    @Test func atMostThreeShelvesAreReturned() {
        let buckets: [AffinityBucket] = [
            .genre("A"), .genre("B"), .genre("C"), .genre("D"), .genre("E"),
        ]
        let signals = buckets.enumerated().flatMap { index, bucket in
            (0 ..< (5 - index)).map { signal("s\(bucket.identity)\($0)", buckets: [bucket], played: now) }
        }
        let scores = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let shelves = AffinitySelection.select(signals: signals, scores: scores, qualifying: buckets)
        #expect(shelves.count == AffinityTuning.maxShelves)
    }

    @Test func aPlayedAndFavoritedSourceOutranksAFavoriteOnlyOneAsSeed() {
        let signals = [
            signal("a-fav-only", buckets: [.genre("Horror")], favorite: true),
            signal("z-both", buckets: [.genre("Horror")], played: now, favorite: true),
        ]
        let scores = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let shelves = AffinitySelection.select(signals: signals, scores: scores, qualifying: [.genre("Horror")])
        let similar = shelves.first {
            if case .similar = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(similar?.kind == .similar(seedID: "z-both", seedName: "Title z-both", wasPlayed: true))
        #expect(similar?.title == "Because you watched Title z-both")
    }

    @Test func tiedFavoriteSeedsResolveByIdRegardlessOfInputOrder() {
        let a = signal("aaa", buckets: [.genre("Horror")], favorite: true)
        let b = signal("bbb", buckets: [.genre("Horror")], favorite: true)
        let c = signal("ccc", buckets: [.genre("Horror")], favorite: true)
        let forward = AffinitySelection.select(
            signals: [a, b, c],
            scores: AffinityScoring.score(signals: [a, b, c], favoritedPeople: [], now: now),
            qualifying: [.genre("Horror")],
        )
        let reversed = AffinitySelection.select(
            signals: [c, b, a],
            scores: AffinityScoring.score(signals: [c, b, a], favoritedPeople: [], now: now),
            qualifying: [.genre("Horror")],
        )
        #expect(forward.map(\.title) == reversed.map(\.title))
        let similar = forward.first {
            if case .similar = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(similar?.title == "Because you favorited Title aaa")
    }

    @Test func personShelvesCarryTheirName() {
        let signals = (0 ..< 3).map {
            signal("m\($0)", buckets: [.person("p1")], played: now, names: ["p1": "Ada Lovelace"])
        }
        let scores = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let shelves = AffinitySelection.select(signals: signals, scores: scores, qualifying: [.person("p1")])
        let person = shelves.first { $0.kind == .bucket(.person("p1")) }
        #expect(person?.title == "More from Ada Lovelace")
        #expect(person?.personName == "Ada Lovelace")
    }

    @Test func genreDecadeShelvesReadAsTheArchetypeSays() {
        let signals = (0 ..< 3).map { signal("m\($0)", buckets: [.genreDecade("Horror", 1980)], played: now) }
        let scores = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let shelves = AffinitySelection.select(signals: signals, scores: scores, qualifying: [.genreDecade("Horror", 1980)])
        #expect(shelves.first?.title == "More horror from the 1980s")
    }

    @Test func rankingIsStableWhenScoresTie() {
        let signals = (0 ..< 3).map { signal("m\($0)", buckets: [.genre("Alpha"), .genre("Beta")], played: now) }
        let scores = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let first = AffinitySelection.select(signals: signals, scores: scores, qualifying: [.genre("Beta"), .genre("Alpha")])
        let second = AffinitySelection.select(signals: signals, scores: scores, qualifying: [.genre("Alpha"), .genre("Beta")])
        #expect(first.map(\.title) == second.map(\.title))
    }

    @Test func lowerRankedShelvesLoseItemsAlreadyShownAbove() {
        let top = AffinityShelfDescriptor(kind: .bucket(.genre("A")), title: "A", score: 10, personName: nil)
        let low = AffinityShelfDescriptor(kind: .bucket(.genre("B")), title: "B", score: 1, personName: nil)
        let deduped = AffinitySelection.deOverlap(shelves: [
            (top, (0 ..< 8).map { item("i\($0)") }),
            (low, (0 ..< 8).map { item("i\($0)") } + (8 ..< 14).map { item("i\($0)") }),
        ])
        #expect(deduped[0].1.count == 8)
        #expect(deduped[1].1.map(\.id) == ["i8", "i9", "i10", "i11", "i12", "i13"])
    }

    @Test func aShelfFallingBelowTheMinimumAfterDedupeIsDropped() {
        let top = AffinityShelfDescriptor(kind: .bucket(.genre("A")), title: "A", score: 10, personName: nil)
        let low = AffinityShelfDescriptor(kind: .bucket(.genre("B")), title: "B", score: 1, personName: nil)
        let deduped = AffinitySelection.deOverlap(shelves: [
            (top, (0 ..< 8).map { item("i\($0)") }),
            (low, (0 ..< 8).map { item("i\($0)") } + [item("i99")]),
        ])
        #expect(deduped.count == 1)
    }
}

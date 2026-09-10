import Foundation
@testable import JellyfinKit
import Testing

@Suite("AffinityThreshold")
struct AffinityThresholdTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    private func signals(_ count: Int, buckets: Set<AffinityBucket>) -> [AffinitySignal] {
        (0 ..< count).map {
            AffinitySignal(
                sourceID: "s\($0)",
                name: "S\($0)",
                buckets: buckets,
                personNames: [:],
                lastPlayed: now,
                isFavorite: false,
            )
        }
    }

    @Test func onlyBucketsAtOrAboveTheFloorAskForADenominator() {
        let scores = AffinityScoring.score(
            signals: signals(2, buckets: [.genre("Horror")]),
            favoritedPeople: [],
            now: now,
        )
        #expect(AffinityThreshold.candidateBuckets(scores: scores).isEmpty)
    }

    @Test func anOverRepresentedBucketQualifies() {
        // 6 of 40 watched (15%) against 4% of the library → 3.75x.
        var all = signals(6, buckets: [.genre("Horror")])
        all += (0 ..< 34).map {
            AffinitySignal(
                sourceID: "d\($0)", name: "D", buckets: [.genre("Drama")],
                personNames: [:], lastPlayed: now, isFavorite: false,
            )
        }
        let scores = AffinityScoring.score(signals: all, favoritedPeople: [], now: now)
        let qualifying = AffinityThreshold.qualifying(
            scores: scores,
            denominators: [.genre("Horror"): 40, .genre("Drama"): 250],
            librarySize: 1000,
        )
        #expect(qualifying.contains(.genre("Horror")))
    }

    /// The "Drama" case: large, but not over-represented.
    @Test func aLargeButProportionateBucketIsSkipped() {
        var all = signals(6, buckets: [.genre("Horror")])
        all += (0 ..< 34).map {
            AffinitySignal(
                sourceID: "d\($0)", name: "D", buckets: [.genre("Drama")],
                personNames: [:], lastPlayed: now, isFavorite: false,
            )
        }
        let scores = AffinityScoring.score(signals: all, favoritedPeople: [], now: now)
        let qualifying = AffinityThreshold.qualifying(
            scores: scores,
            denominators: [.genre("Horror"): 40, .genre("Drama"): 850],
            librarySize: 1000,
        )
        #expect(!qualifying.contains(.genre("Drama")))
    }

    /// Spec § 5.2 fixture: favorites-only histories must be able to qualify.
    @Test func aFavoritesOnlyHistoryCanQualify() {
        let favorites = (0 ..< 4).map {
            AffinitySignal(
                sourceID: "f\($0)", name: "F", buckets: [.genre("Horror")],
                personNames: [:], lastPlayed: nil, isFavorite: true,
            )
        }
        let scores = AffinityScoring.score(signals: favorites, favoritedPeople: [], now: now)
        let qualifying = AffinityThreshold.qualifying(
            scores: scores,
            denominators: [.genre("Horror"): 40],
            librarySize: 1000,
        )
        #expect(qualifying == [.genre("Horror")])
    }

    @Test func aMissingOrZeroDenominatorDisqualifies() {
        let scores = AffinityScoring.score(signals: signals(5, buckets: [.genre("Horror")]), favoritedPeople: [], now: now)
        #expect(AffinityThreshold.qualifying(scores: scores, denominators: [:], librarySize: 1000).isEmpty)
        #expect(AffinityThreshold.qualifying(
            scores: scores, denominators: [.genre("Horror"): 0], librarySize: 1000,
        ).isEmpty)
    }

    @Test func aFavoritedActorWithNoPlayedWorkStaysBelowTheFloor() {
        let scores = AffinityScoring.score(
            signals: [],
            favoritedPeople: [Person(id: "p1", name: "P")],
            now: now,
        )
        #expect(AffinityThreshold.candidateBuckets(scores: scores).isEmpty)
    }

    @Test func aFavoritedActorWithThreePlayedFilmsQualifies() {
        let films = (0 ..< 3).map {
            AffinitySignal(
                sourceID: "m\($0)", name: "M", buckets: [.person("p1")],
                personNames: ["p1": "P"], lastPlayed: now, isFavorite: false,
            )
        }
        let scores = AffinityScoring.score(
            signals: films,
            favoritedPeople: [Person(id: "p1", name: "P")],
            now: now,
        )
        #expect(scores.contributors[.person("p1")]?.count == 4)
        let qualifying = AffinityThreshold.qualifying(
            scores: scores,
            denominators: [.person("p1"): 5],
            librarySize: 1000,
        )
        #expect(qualifying == [.person("p1")])
    }
}

import Foundation
@testable import JellyfinKit
import Testing

@Suite("AffinityScoring")
struct AffinityScoringTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    private func signal(
        _ id: String,
        buckets: Set<AffinityBucket>,
        played: Date? = nil,
        favorite: Bool = false,
    ) -> AffinitySignal {
        AffinitySignal(
            sourceID: id,
            name: id,
            buckets: buckets,
            personNames: [:],
            lastPlayed: played,
            isFavorite: favorite,
        )
    }

    @Test func aPlayTodayWeighsOne() {
        #expect(abs(AffinityScoring.recencyWeight(playDate: now, now: now) - 1.0) < 0.0001)
    }

    @Test func aPlayOneHalfLifeAgoWeighsAHalf() {
        let old = now.addingTimeInterval(-AffinityTuning.halfLifeDays * 86400)
        #expect(abs(AffinityScoring.recencyWeight(playDate: old, now: now) - 0.5) < 0.0001)
    }

    /// Server clock skew is real; a negative age must not weigh above 1.
    @Test func aFuturePlayDateClampsToOne() {
        let future = now.addingTimeInterval(86400)
        #expect(AffinityScoring.recencyWeight(playDate: future, now: now) == 1.0)
    }

    @Test func favoritesDoNotDecay() {
        let ancient = now.addingTimeInterval(-3650 * 86400)
        let scores = AffinityScoring.score(
            signals: [signal("s1", buckets: [.genre("Horror")], played: ancient, favorite: true)],
            favoritedPeople: [],
            now: now,
        )
        #expect(scores.byBucket[.genre("Horror")]! >= AffinityTuning.favoriteWeight)
    }

    @Test func aSourceBothPlayedAndFavoritedCarriesBothWeights() {
        let scores = AffinityScoring.score(
            signals: [signal("s1", buckets: [.genre("Horror")], played: now, favorite: true)],
            favoritedPeople: [],
            now: now,
        )
        #expect(abs(scores.byBucket[.genre("Horror")]! - (AffinityTuning.favoriteWeight + 1.0)) < 0.0001)
    }

    @Test func contributorCountsDistinctSourcesNotSignals() {
        let scores = AffinityScoring.score(
            signals: [signal("s1", buckets: [.genre("Horror")], played: now, favorite: true)],
            favoritedPeople: [],
            now: now,
        )
        #expect(scores.contributors[.genre("Horror")] == ["s1"])
    }

    /// Spec § 5.2: favorited-person weight is eligible for person buckets only.
    @Test func favoritedPeopleWeightStaysOutOfTheGenreDenominator() {
        let signals = [signal("s1", buckets: [.genre("Horror")], played: now)]
        let without = AffinityScoring.score(signals: signals, favoritedPeople: [], now: now)
        let with = AffinityScoring.score(
            signals: signals,
            favoritedPeople: (0 ..< 20).map { Person(id: "p\($0)", name: "P\($0)") },
            now: now,
        )
        #expect(without.eligibleSignalWeight(for: .genre("Horror"))
            == with.eligibleSignalWeight(for: .genre("Horror")))
    }

    @Test func favoritedPeopleWeightIsEligibleForPersonBuckets() {
        let scores = AffinityScoring.score(
            signals: [signal("s1", buckets: [.person("p1")], played: now)],
            favoritedPeople: [Person(id: "p1", name: "P")],
            now: now,
        )
        #expect(scores.eligibleSignalWeight(for: .person("p1"))
            > scores.eligibleSignalWeight(for: .genre("Horror")))
    }

    @Test func aFavoritedPersonScoresTheirOwnBucket() {
        let scores = AffinityScoring.score(
            signals: [],
            favoritedPeople: [Person(id: "p1", name: "P")],
            now: now,
        )
        #expect(scores.byBucket[.person("p1")] == AffinityTuning.favoriteWeight)
        #expect(scores.contributors[.person("p1")] == ["p1"])
    }

    @Test func sourceWeightIsTheCombinedProvenanceWeight() {
        let scores = AffinityScoring.score(
            signals: [signal("s1", buckets: [.genre("Horror")], played: now, favorite: true)],
            favoritedPeople: [],
            now: now,
        )
        #expect(abs(scores.sourceWeights["s1"]! - (AffinityTuning.favoriteWeight + 1.0)) < 0.0001)
    }
}

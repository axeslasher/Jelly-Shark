import Foundation

/// Bucket scores, contributor sets, and the signal mass each bucket kind is
/// eligible to be measured against.
public struct AffinityScores: Sendable {
    public let byBucket: [AffinityBucket: Double]
    /// Distinct sources — item ids and favorited person ids — that gave a
    /// bucket any weight. A source played *and* favorited counts once.
    public let contributors: [AffinityBucket: Set<String>]
    /// Combined weight per source, which is what seeds the similar-items
    /// shelf (§ 7.1). Keyed by `AffinitySignal.sourceID`.
    public let sourceWeights: [String: Double]
    /// Total weight of item signals — plays plus favorited items.
    public let itemSignalWeight: Double
    /// Total weight of favorited-person signals.
    public let favoritedPeopleWeight: Double

    /// The signal mass a bucket of this kind can actually receive.
    ///
    /// A favorited person contributes to person buckets but can never belong
    /// to a genre bucket, so its weight must not sit in a genre bucket's
    /// denominator — otherwise favoriting twenty actors would shrink an
    /// unchanged Horror shelf's share below the ratio.
    public func eligibleSignalWeight(for bucket: AffinityBucket) -> Double {
        switch bucket {
        case .genre, .genreDecade: itemSignalWeight
        case .person: itemSignalWeight + favoritedPeopleWeight
        }
    }
}

public enum AffinityScoring {
    /// Exponential decay. `max(0, …)` clamps a future play date: server
    /// clock skew is real, and a negative age would weigh above 1.
    public static func recencyWeight(playDate: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(playDate) / 86400)
        return pow(0.5, days / AffinityTuning.halfLifeDays)
    }

    public static func score(
        signals: [AffinitySignal],
        favoritedPeople: [Person],
        now: Date,
    ) -> AffinityScores {
        var byBucket: [AffinityBucket: Double] = [:]
        var contributors: [AffinityBucket: Set<String>] = [:]
        var sourceWeights: [String: Double] = [:]
        var itemSignalWeight = 0.0

        for signal in signals {
            var weight = 0.0
            if let played = signal.lastPlayed {
                weight += recencyWeight(playDate: played, now: now)
            }
            if signal.isFavorite {
                weight += AffinityTuning.favoriteWeight
            }
            guard weight > 0 else { continue }

            sourceWeights[signal.sourceID] = weight
            itemSignalWeight += weight
            for bucket in signal.buckets {
                byBucket[bucket, default: 0] += weight
                contributors[bucket, default: []].insert(signal.sourceID)
            }
        }

        var favoritedPeopleWeight = 0.0
        for person in favoritedPeople {
            let bucket = AffinityBucket.person(person.id)
            byBucket[bucket, default: 0] += AffinityTuning.favoriteWeight
            contributors[bucket, default: []].insert(person.id)
            favoritedPeopleWeight += AffinityTuning.favoriteWeight
        }

        return AffinityScores(
            byBucket: byBucket,
            contributors: contributors,
            sourceWeights: sourceWeights,
            itemSignalWeight: itemSignalWeight,
            favoritedPeopleWeight: favoritedPeopleWeight,
        )
    }
}

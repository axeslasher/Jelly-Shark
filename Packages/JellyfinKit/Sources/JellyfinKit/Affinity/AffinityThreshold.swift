import Foundation

/// The two-part gate a bucket clears before it can mint a shelf.
public enum AffinityThreshold {
    /// Buckets that cleared the absolute floor and therefore deserve a
    /// denominator probe. Probing only these is what keeps the network cost
    /// a handful of requests rather than one per genre in the library.
    public static func candidateBuckets(scores: AffinityScores) -> [AffinityBucket] {
        scores.contributors
            .filter { $0.value.count >= AffinityTuning.minContributors }
            .keys
            .sorted { $0.identity < $1.identity }
    }

    /// Buckets clearing both halves: the contributor floor, and
    /// over-representation against the bucket's share of the library.
    ///
    /// - Parameters:
    ///   - denominators: `libraryCount` per bucket, from the count probe.
    ///     A bucket with no denominator cannot be measured and is dropped —
    ///     never assumed over-represented.
    ///   - librarySize: the universe's item count (§ 5.3).
    public static func qualifying(
        scores: AffinityScores,
        denominators: [AffinityBucket: Int],
        librarySize: Int,
    ) -> [AffinityBucket] {
        guard librarySize > 0 else { return [] }

        return candidateBuckets(scores: scores).filter { bucket in
            guard let libraryCount = denominators[bucket], libraryCount > 0,
                  let score = scores.byBucket[bucket]
            else { return false }

            let eligible = scores.eligibleSignalWeight(for: bucket)
            guard eligible > 0 else { return false }

            let affinityShare = score / eligible
            let libraryShare = Double(libraryCount) / Double(librarySize)
            return affinityShare / libraryShare >= AffinityTuning.minRatio
        }
    }
}

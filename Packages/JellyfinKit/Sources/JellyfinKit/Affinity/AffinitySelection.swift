import Foundation

/// Turns qualifying buckets into a ranked, capped, non-overlapping shelf set.
public enum AffinitySelection {
    /// - Parameter qualifying: buckets that cleared both halves of the
    ///   threshold. **Empty means zero shelves** — the similar-items
    ///   candidate is not allowed to resurrect a shelf from a history where
    ///   nothing qualified.
    public static func select(
        signals: [AffinitySignal],
        scores: AffinityScores,
        qualifying: [AffinityBucket],
    ) -> [AffinityShelfDescriptor] {
        guard !qualifying.isEmpty else { return [] }

        let names = personNames(from: signals)
        var candidates = qualifying.map { bucket in
            AffinityShelfDescriptor(
                kind: .bucket(bucket),
                title: title(for: bucket, personNames: names),
                score: scores.byBucket[bucket] ?? 0,
                personName: personName(for: bucket, personNames: names),
            )
        }

        if let similar = similarCandidate(signals: signals, scores: scores, qualifying: Set(qualifying)) {
            candidates.append(similar)
        }

        return Array(candidates.sorted(by: ranked).prefix(AffinityTuning.maxShelves))
    }

    /// Score descending, then archetype rank, then identity. Identity is
    /// unique across candidates, so this is a total order — a float tie can
    /// never leave the result depending on input order.
    private static func ranked(_ a: AffinityShelfDescriptor, _ b: AffinityShelfDescriptor) -> Bool {
        if a.score != b.score {
            return a.score > b.score
        }
        if a.kind.archetypeRank != b.kind.archetypeRank {
            return a.kind.archetypeRank < b.kind.archetypeRank
        }
        return a.kind.identity < b.kind.identity
    }

    private static func similarCandidate(
        signals: [AffinitySignal],
        scores: AffinityScores,
        qualifying: Set<AffinityBucket>,
    ) -> AffinityShelfDescriptor? {
        // The seed must itself belong to a qualifying bucket, or a single
        // played item would mint a shelf from a history where nothing
        // cleared the floor.
        let eligible = signals.filter { !$0.buckets.isDisjoint(with: qualifying) }
        guard let seed = eligible.sorted(by: { seedOrder($0, $1, weights: scores.sourceWeights) }).first,
              let seedScore = seed.buckets
              .filter({ qualifying.contains($0) })
              .compactMap({ scores.byBucket[$0] })
              .max()
        else { return nil }

        let wasPlayed = seed.lastPlayed != nil
        return AffinityShelfDescriptor(
            kind: .similar(seedID: seed.sourceID, seedName: seed.name, wasPlayed: wasPlayed),
            title: wasPlayed ? "Because you watched \(seed.name)" : "Because you favorited \(seed.name)",
            score: seedScore * AffinityTuning.similarShelfWeight,
            personName: nil,
        )
    }

    /// Combined source weight descending, then most recent play, then
    /// provenance, then id. "Highest-weighted signal" is not a total order
    /// on its own — every favorite carries exactly `favoriteWeight` — and
    /// server response order must never decide which seed wins.
    private static func seedOrder(
        _ a: AffinitySignal,
        _ b: AffinitySignal,
        weights: [String: Double],
    ) -> Bool {
        // Weights come from `AffinityScores`, never recomputed here: a fresh
        // `Date()` would make the seed depend on wall-clock at call time and
        // disagree with the `now` the bucket scores used.
        let aWeight = weights[a.sourceID] ?? 0
        let bWeight = weights[b.sourceID] ?? 0
        if aWeight != bWeight {
            return aWeight > bWeight
        }

        // Rule 2 (most recent play, played-before-unplayed) subsumes the
        // spec's rule 3: a source with any play provenance already sorts
        // above one without. Rule 3 survives as the title rule below, not as
        // a comparison — writing it here as well would be dead code.
        switch (a.lastPlayed, b.lastPlayed) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }

        return a.sourceID < b.sourceID
    }

    private static func personNames(from signals: [AffinitySignal]) -> [String: String] {
        signals.reduce(into: [String: String]()) { names, signal in
            names.merge(signal.personNames) { current, _ in current }
        }
    }

    private static func personName(for bucket: AffinityBucket, personNames: [String: String]) -> String? {
        guard case let .person(id) = bucket else { return nil }
        return personNames[id]
    }

    private static func title(for bucket: AffinityBucket, personNames: [String: String]) -> String {
        switch bucket {
        case let .genre(name):
            "More \(name.lowercased())"
        case let .genreDecade(name, decade):
            "More \(name.lowercased()) from the \(decade)s"
        case let .person(id):
            "More from \(personNames[id] ?? "this filmmaker")"
        }
    }

    /// Drop from each shelf any item already shown above it, then suppress a
    /// shelf left too thin. Two near-identical adjacent rows read as a bug.
    public static func deOverlap(
        shelves: [(AffinityShelfDescriptor, [MediaItem])],
    ) -> [(AffinityShelfDescriptor, [MediaItem])] {
        var seen: Set<String> = []
        var result: [(AffinityShelfDescriptor, [MediaItem])] = []

        for (descriptor, items) in shelves {
            let fresh = items.filter { !seen.contains($0.id) }
            guard fresh.count >= AffinityTuning.minShelfItems else { continue }
            seen.formUnion(fresh.map(\.id))
            result.append((descriptor, fresh))
        }

        return result
    }
}

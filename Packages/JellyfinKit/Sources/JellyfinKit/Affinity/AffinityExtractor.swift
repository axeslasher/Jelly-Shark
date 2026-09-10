import Foundation

/// Turns one `MediaItem` into the buckets it contributes to.
///
/// The only per-kind code in the engine, alongside the count probe's
/// filters. Everything downstream treats buckets uniformly.
public enum AffinityExtractor {
    /// - Parameter favoritedPersonIDs: people the viewer favorited. A
    ///   favorite is an explicit statement, so it unlocks that person's
    ///   credits whatever their kind — without this, a favorited actor's
    ///   bucket would sit at one contributor forever and never clear the
    ///   floor, while still diluting every other person bucket's share.
    public static func buckets(for item: MediaItem, favoritedPersonIDs: Set<String>) -> Set<AffinityBucket> {
        var buckets: Set<AffinityBucket> = []

        let decade = item.productionYear.map { $0 / 10 * 10 }
        for genre in item.genres ?? [] {
            buckets.insert(.genre(genre))
            if let decade {
                buckets.insert(.genreDecade(genre, decade))
            }
        }

        for credit in eligibleCredits(of: item, favoritedPersonIDs: favoritedPersonIDs) {
            buckets.insert(.person(credit.id))
        }

        return buckets
    }

    /// Names for the person buckets this item mints, so a shelf title
    /// survives a cold cache without a `getPerson` round-trip.
    public static func personNames(for item: MediaItem, favoritedPersonIDs: Set<String>) -> [String: String] {
        var names: [String: String] = [:]
        for credit in eligibleCredits(of: item, favoritedPersonIDs: favoritedPersonIDs) {
            names[credit.id] = credit.name
        }
        return names
    }

    private static func eligibleCredits(
        of item: MediaItem,
        favoritedPersonIDs: Set<String>,
    ) -> [CastMember] {
        (item.people ?? []).filter { credit in
            // A fallback id cannot be fetched or navigated to, so it must
            // never mint a shelf — whatever the credit says.
            guard credit.hasServerId else { return false }
            return AffinityTuning.eligiblePersonKinds.contains(credit.kind)
                || favoritedPersonIDs.contains(credit.id)
        }
    }
}

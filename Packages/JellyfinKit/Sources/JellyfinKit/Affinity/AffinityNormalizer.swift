import Foundation

/// Collapses raw fetch results into the signal set the engine scores.
public enum AffinityNormalizer {
    /// - Parameters:
    ///   - playedEpisodes: fetched in their own window, because a shared
    ///     window is truncated server-side before this collapse can run —
    ///     one binge would fill it and exclude every film.
    ///   - seriesMetadata: series items for the ids `playedEpisodes`
    ///     collapse to. Episodes' own genres and people name that episode's
    ///     director, not the show's, so they are discarded.
    public static func normalize(
        playedMovies: [MediaItem],
        playedEpisodes: [MediaItem],
        seriesMetadata: [MediaItem],
        favoritedItems: [MediaItem],
        favoritedPeople: [Person],
    ) -> [AffinitySignal] {
        let favoritedPersonIDs = Set(favoritedPeople.map(\.id))
        let favoritedItemIDs = Set(favoritedItems.map(\.id))

        // Latest play per series, from the episode window alone.
        var seriesLastPlayed: [String: Date] = [:]
        for episode in playedEpisodes {
            guard let seriesID = episode.seriesId,
                  let played = episode.userData?.lastPlayedDate
            else { continue }
            if let existing = seriesLastPlayed[seriesID], existing >= played {
                continue
            }
            seriesLastPlayed[seriesID] = played
        }

        // One entry per source id. A movie that was both played and
        // favorited merges into a single signal carrying both provenances.
        var byID: [String: (item: MediaItem, lastPlayed: Date?, isFavorite: Bool)] = [:]

        func merge(_ item: MediaItem, lastPlayed: Date?, isFavorite: Bool) {
            if let existing = byID[item.id] {
                byID[item.id] = (
                    existing.item,
                    [existing.lastPlayed, lastPlayed].compactMap(\.self).max(),
                    existing.isFavorite || isFavorite,
                )
            } else {
                byID[item.id] = (item, lastPlayed, isFavorite)
            }
        }

        for movie in playedMovies {
            merge(movie, lastPlayed: movie.userData?.lastPlayedDate, isFavorite: favoritedItemIDs.contains(movie.id))
        }
        for series in seriesMetadata where seriesLastPlayed[series.id] != nil {
            merge(series, lastPlayed: seriesLastPlayed[series.id], isFavorite: favoritedItemIDs.contains(series.id))
        }
        // `lastPlayed: nil` on purpose. The two play windows are the *only*
        // source of play provenance: a favorite outside them would otherwise
        // gain play weight — and a "Because you watched" title — from a
        // `lastPlayedDate` the windows deliberately excluded as stale.
        // `merge` keeps the later of the two dates, so an item in both a play
        // window and this list still carries its real play date.
        for favorite in favoritedItems {
            merge(favorite, lastPlayed: nil, isFavorite: true)
        }

        return byID.values
            .map { entry in
                AffinitySignal(
                    sourceID: entry.item.id,
                    name: entry.item.name,
                    buckets: AffinityExtractor.buckets(for: entry.item, favoritedPersonIDs: favoritedPersonIDs),
                    personNames: AffinityExtractor.personNames(for: entry.item, favoritedPersonIDs: favoritedPersonIDs),
                    lastPlayed: entry.lastPlayed,
                    isFavorite: entry.isFavorite,
                )
            }
            // Deterministic order so everything downstream — scoring sums,
            // the fingerprint, the seed choice — sees the same input twice.
            .sorted { $0.sourceID < $1.sourceID }
    }
}

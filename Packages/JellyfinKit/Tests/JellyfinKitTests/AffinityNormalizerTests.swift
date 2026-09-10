import Foundation
@testable import JellyfinKit
import Testing

@Suite("AffinityNormalizer")
struct AffinityNormalizerTests {
    private let jan1 = Date(timeIntervalSince1970: 1_767_225_600)

    private func movie(_ id: String, genres: [String] = ["Horror"], played: Date? = nil) -> MediaItem {
        MediaItem(
            id: id,
            name: "Movie \(id)",
            type: .movie,
            productionYear: 1987,
            genres: genres,
            userData: played.map { UserData(lastPlayedDate: $0) },
        )
    }

    private func episode(_ id: String, seriesId: String, played: Date) -> MediaItem {
        MediaItem(
            id: id,
            name: "Episode \(id)",
            type: .episode,
            userData: UserData(lastPlayedDate: played),
            seriesId: seriesId,
        )
    }

    private func series(_ id: String, genres: [String] = ["Drama"]) -> MediaItem {
        MediaItem(id: id, name: "Series \(id)", type: .series, productionYear: 1999, genres: genres)
    }

    /// Spec § 5.1: a 60-episode binge is one taste statement, not sixty.
    @Test func episodesOfOneSeriesCollapseToASingleSignal() {
        let episodes = (0 ..< 60).map { episode("e\($0)", seriesId: "s1", played: jan1.addingTimeInterval(Double($0))) }
        let signals = AffinityNormalizer.normalize(
            playedMovies: [],
            playedEpisodes: episodes,
            seriesMetadata: [series("s1")],
            favoritedItems: [],
            favoritedPeople: [],
        )
        #expect(signals.count == 1)
        #expect(signals[0].sourceID == "s1")
    }

    @Test func aCollapsedSeriesTakesItsMostRecentEpisodePlayDate() {
        let episodes = [
            episode("e1", seriesId: "s1", played: jan1),
            episode("e2", seriesId: "s1", played: jan1.addingTimeInterval(3600)),
        ]
        let signals = AffinityNormalizer.normalize(
            playedMovies: [],
            playedEpisodes: episodes,
            seriesMetadata: [series("s1")],
            favoritedItems: [],
            favoritedPeople: [],
        )
        #expect(signals[0].lastPlayed == jan1.addingTimeInterval(3600))
    }

    @Test func aCollapsedSeriesTakesItsBucketsFromSeriesMetadataNotEpisodes() {
        let signals = AffinityNormalizer.normalize(
            playedMovies: [],
            playedEpisodes: [episode("e1", seriesId: "s1", played: jan1)],
            seriesMetadata: [series("s1", genres: ["Sci-Fi"])],
            favoritedItems: [],
            favoritedPeople: [],
        )
        #expect(signals[0].buckets.contains(.genre("Sci-Fi")))
    }

    @Test func aSeriesWithNoMetadataYieldsNoSignal() {
        let signals = AffinityNormalizer.normalize(
            playedMovies: [],
            playedEpisodes: [episode("e1", seriesId: "s1", played: jan1)],
            seriesMetadata: [],
            favoritedItems: [],
            favoritedPeople: [],
        )
        #expect(signals.isEmpty)
    }

    /// Spec § 5.2: one source, both weights.
    @Test func anItemBothPlayedAndFavoritedIsOneSignal() {
        let m = movie("m1", played: jan1)
        let signals = AffinityNormalizer.normalize(
            playedMovies: [m],
            playedEpisodes: [],
            seriesMetadata: [],
            favoritedItems: [m],
            favoritedPeople: [],
        )
        #expect(signals.count == 1)
        #expect(signals[0].lastPlayed == jan1)
        #expect(signals[0].isFavorite)
    }

    /// The play windows are the only source of play provenance: a favorite
    /// outside them must not gain play weight from a stale lastPlayedDate.
    @Test func aFavoriteOutsideThePlayWindowsCarriesNoPlayDate() {
        let stale = MediaItem(
            id: "f1", name: "F", type: .movie, genres: ["Horror"],
            userData: UserData(lastPlayedDate: jan1.addingTimeInterval(-99999)),
        )
        let signals = AffinityNormalizer.normalize(
            playedMovies: [],
            playedEpisodes: [],
            seriesMetadata: [],
            favoritedItems: [stale],
            favoritedPeople: [],
        )
        #expect(signals[0].lastPlayed == nil)
        #expect(signals[0].isFavorite)
    }

    @Test func anItemInBothAPlayWindowAndTheFavoritesListKeepsItsPlayDate() {
        let m = movie("m1", played: jan1)
        let signals = AffinityNormalizer.normalize(
            playedMovies: [m],
            playedEpisodes: [],
            seriesMetadata: [],
            favoritedItems: [m],
            favoritedPeople: [],
        )
        #expect(signals[0].lastPlayed == jan1)
    }

    @Test func favoritedPeopleUnlockTheirCreditsAcrossEverySignal() {
        let people = [CastMember(id: "p-act", name: "Act", kind: "Actor")]
        let m = MediaItem(id: "m1", name: "M", type: .movie, genres: ["Horror"], people: people)
        let signals = AffinityNormalizer.normalize(
            playedMovies: [m],
            playedEpisodes: [],
            seriesMetadata: [],
            favoritedItems: [],
            favoritedPeople: [Person(id: "p-act", name: "Act")],
        )
        #expect(signals[0].buckets.contains(.person("p-act")))
    }

    @Test func movieSignalsSurviveAlongsideABinge() {
        let episodes = (0 ..< 60).map { episode("e\($0)", seriesId: "s1", played: jan1) }
        let movies = (0 ..< 40).map { movie("m\($0)", played: jan1) }
        let signals = AffinityNormalizer.normalize(
            playedMovies: movies,
            playedEpisodes: episodes,
            seriesMetadata: [series("s1")],
            favoritedItems: [],
            favoritedPeople: [],
        )
        #expect(signals.count == 41)
    }
}

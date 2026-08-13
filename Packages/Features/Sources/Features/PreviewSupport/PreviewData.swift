import DesignSystem
import Foundation
import JellyfinKit

#if DEBUG
    /// Fictional `MediaItem` fixtures for `#Preview` bodies. Debug-only; the
    /// unqualified `PreviewData` inside Features is this enum, and the strings
    /// and hashes come from `DesignSystem.PreviewData`.
    ///
    /// Fixtures set blur hashes but leave the image *tags* nil: previews run
    /// with `client == nil`, so a tag could only build a doomed URL, while a
    /// hash with no URL renders synthesized artwork immediately — the same
    /// path production takes while artwork is in flight.
    enum PreviewData {
        private typealias Shared = DesignSystem.PreviewData

        static let movie = MediaItem(
            id: "preview-movie",
            name: Shared.movieTitles[0],
            type: .movie,
            overview: Shared.overview,
            productionYear: 2024,
            runTimeTicks: 72_000_000_000,
            communityRating: 8.5,
            criticRating: 93,
            officialRating: "PG-13",
            tagline: "Every map ends somewhere.",
            genres: ["Crime", "Drama", "Thriller"],
            studios: ["Gable House Pictures"],
            premiereDate: Date(timeIntervalSince1970: 1_700_000_000),
            technicalInfo: MediaTechnicalInfo(
                resolution: "4K",
                videoRange: "Dolby Vision",
                audioFormat: "Dolby Atmos",
                originalAudioLanguage: "English",
                audioLanguages: ["English", "French"],
                subtitleLanguages: ["English", "French", "Spanish"],
                hasSDHSubtitles: true,
                fileName: "The.Cartographers.Daughter.2024.2160p.DV.mkv",
                fileSizeBytes: 42_000_000_000,
                container: "MKV",
                videoCodec: "HEVC",
                bitrate: 24_500_000,
                frameRate: 23.976,
            ),
            imageTags: ImageTags(
                primaryBlurHash: Shared.posterHashes[0],
                backdropBlurHash: Shared.backdropHashes[0],
            ),
            people: cast,
        )

        static let longTitleMovie = MediaItem(
            id: "preview-long-title",
            name: Shared.longTitle,
            type: .movie,
            productionYear: 1987,
            runTimeTicks: 98_000_000_000,
            imageTags: ImageTags(primaryBlurHash: Shared.posterHashes[8]),
        )

        /// No hashes and no tags: exercises the icon-placeholder path.
        static let missingArtwork = MediaItem(
            id: "preview-missing-artwork",
            name: Shared.shortTitle,
            type: .movie,
        )

        static let episode = MediaItem(
            id: "preview-episode",
            name: "The Weather Room",
            type: .episode,
            overview: Shared.overview,
            runTimeTicks: 27_000_000_000,
            imageTags: ImageTags(thumbBlurHash: Shared.backdropHashes[1]),
            seriesId: "preview-series",
            seriesName: Shared.movieTitles[2],
            seasonId: "preview-season-2",
            seasonName: "Season 2",
            indexNumber: 4,
            parentIndexNumber: 2,
        )

        /// Two seasons of `series`, for the season-anchor shelf.
        /// (`number` is annotated because its only typed use is the `Int?`
        /// `indexNumber:` parameter — left to inference, Swift binds it as
        /// `Int?` and every interpolation renders "Optional(1)".)
        static let seasons: [MediaItem] = (1 ... 2).map { (number: Int) in
            MediaItem(
                id: "preview-season-\(number)",
                name: "Season \(number)",
                type: .season,
                seriesId: "preview-series",
                seriesName: Shared.movieTitles[2],
                indexNumber: number,
            )
        }

        /// Eight episodes across the two seasons — watched, in-progress, and
        /// unwatched variety for the playback badges.
        static let seasonEpisodes: [MediaItem] = [
            "The Drowned Antenna",
            "Chart and Compass",
            "A Room Above the Tide",
            "The Ferry at Night",
            "Low Water Mark",
            "The Keeper's Ledger",
            "Nine Lamps Burning",
            "Last Signal",
        ].enumerated().map { index, name in
            let season = index < 4 ? 1 : 2
            return MediaItem(
                id: "preview-episode-\(index + 1)",
                name: name,
                type: .episode,
                overview: Shared.overview,
                runTimeTicks: Int64(24 + index) * 60 * 10_000_000,
                imageTags: ImageTags(thumbBlurHash: Shared.backdropHashes[index % Shared.backdropHashes.count]),
                userData: UserData(
                    playbackPositionTicks: index == 2 ? 9_600_000_000 : nil,
                    played: index < 2,
                ),
                seriesId: "preview-series",
                seriesName: Shared.movieTitles[2],
                seasonId: "preview-season-\(season)",
                seasonName: "Season \(season)",
                indexNumber: index % 4 + 1,
                parentIndexNumber: season,
            )
        }

        static let series = MediaItem(
            id: "preview-series",
            name: Shared.movieTitles[2],
            type: .series,
            overview: Shared.overview,
            productionYear: 2019,
            officialRating: "TV-MA",
            genres: ["Mystery", "Drama"],
            premiereDate: Date(timeIntervalSince1970: 1_550_000_000),
            endDate: Date(timeIntervalSince1970: 1_680_000_000),
            status: "Ended",
            childCount: 3,
            imageTags: ImageTags(
                primaryBlurHash: Shared.posterHashes[4],
                backdropBlurHash: Shared.backdropHashes[3],
            ),
            userData: UserData(unplayedItemCount: 5),
        )

        static let inProgressMovie = MediaItem(
            id: "preview-in-progress",
            name: Shared.movieTitles[7],
            type: .movie,
            productionYear: 2021,
            runTimeTicks: 66_000_000_000,
            imageTags: ImageTags(primaryBlurHash: Shared.posterHashes[7]),
            userData: UserData(
                playbackPositionTicks: 26_400_000_000,
                lastPlayedDate: Date(timeIntervalSince1970: 1_754_000_000),
            ),
        )

        /// Six actors plus a director. IDs avoid the adapter's `person-`
        /// fallback prefix so the cards read as navigable.
        static let cast: [CastMember] = (0 ..< 6).map { index in
            CastMember(
                id: "preview-cast-\(index)",
                name: Shared.peopleNames[index],
                role: Shared.roles[index],
                kind: "Actor",
            )
        } + [
            CastMember(id: "preview-cast-director", name: Shared.peopleNames[6], kind: "Director"),
        ]

        static let person = Person(
            id: "preview-person",
            name: Shared.peopleNames[0],
            biography: "Born in a harbor town that no longer appears on charts, "
                + "they spent a decade mapping coastlines before turning to film, "
                + "and their work has been mistaken for documentary ever since.",
            birthDate: Date(timeIntervalSince1970: -378_691_200),
            birthPlace: "Halberd Creek",
            primaryBlurHash: Shared.posterHashes[6],
        )

        /// A shelf's worth of poster cards — every title paired with a hash.
        static let shelf: [MediaItem] = Array(zip(Shared.movieTitles, Shared.posterHashes).enumerated())
            .map { index, pair in
                MediaItem(
                    id: "preview-shelf-\(index)",
                    name: pair.0,
                    type: .movie,
                    productionYear: 1980 + index * 4,
                    imageTags: ImageTags(primaryBlurHash: pair.1),
                )
            }
    }
#endif

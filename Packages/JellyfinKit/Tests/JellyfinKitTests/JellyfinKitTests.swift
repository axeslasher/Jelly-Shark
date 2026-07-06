import Testing
import Foundation
import JellyfinAPI
@testable import JellyfinKit

@Suite("JellyfinKit Tests")
struct JellyfinKitTests {

    @Suite("User Model")
    struct UserTests {
        @Test("User initialization")
        func userInitialization() {
            let user = User(
                id: "123",
                name: "Test User",
                serverId: "server-1",
                isAdministrator: true
            )

            #expect(user.id == "123")
            #expect(user.name == "Test User")
            #expect(user.serverId == "server-1")
            #expect(user.isAdministrator == true)
        }

        @Test("User is Hashable")
        func userHashable() {
            let user1 = User(id: "123", name: "Test")
            let user2 = User(id: "123", name: "Test")
            #expect(user1 == user2)
        }
    }

    @Suite("MediaItem Model")
    struct MediaItemTests {
        @Test("MediaItem initialization")
        func mediaItemInitialization() {
            let item = MediaItem(
                id: "movie-1",
                name: "Test Movie",
                type: .movie,
                productionYear: 2024,
                runTimeTicks: 72_000_000_000 // 2 hours
            )

            #expect(item.id == "movie-1")
            #expect(item.name == "Test Movie")
            #expect(item.type == .movie)
            #expect(item.productionYear == 2024)
        }

        @Test("Runtime formatting - hours and minutes")
        func formattedRuntimeHoursMinutes() {
            let twoHourMovie = MediaItem(
                id: "1",
                name: "Movie",
                type: .movie,
                runTimeTicks: 72_000_000_000 // 2 hours
            )
            #expect(twoHourMovie.formattedRuntime == "2h 0m")
        }

        @Test("Runtime formatting - minutes only")
        func formattedRuntimeMinutesOnly() {
            let shortVideo = MediaItem(
                id: "2",
                name: "Short",
                type: .video,
                runTimeTicks: 18_000_000_000 // 30 minutes
            )
            #expect(shortVideo.formattedRuntime == "30m")
        }

        @Test("Remaining runtime formats what's left")
        func formattedRemainingRuntime() {
            let item = MediaItem(
                id: "1", name: "Movie", type: .movie,
                runTimeTicks: 72_000_000_000, // 2h
                userData: UserData(playbackPositionTicks: 27_000_000_000) // 45m in
            )
            #expect(item.formattedRemainingRuntime == "1h 15m")

            let unstarted = MediaItem(
                id: "2", name: "Movie", type: .movie, runTimeTicks: 72_000_000_000
            )
            #expect(unstarted.formattedRemainingRuntime == nil)
        }

        @Test("Progress percentage calculation")
        func progressPercentage() {
            let item = MediaItem(
                id: "1",
                name: "Movie",
                type: .movie,
                runTimeTicks: 100_000_000_000,
                userData: UserData(
                    playbackPositionTicks: 50_000_000_000,
                    isFavorite: false,
                    played: false
                )
            )
            #expect(item.progressPercentage == 0.5)
        }

        @Test("Has progress")
        func hasProgress() {
            let inProgressItem = MediaItem(
                id: "1",
                name: "Movie",
                type: .movie,
                runTimeTicks: 100_000_000_000,
                userData: UserData(playbackPositionTicks: 50_000_000_000)
            )
            #expect(inProgressItem.hasProgress == true)

            let notStartedItem = MediaItem(
                id: "2",
                name: "Movie 2",
                type: .movie,
                runTimeTicks: 100_000_000_000
            )
            #expect(notStartedItem.hasProgress == false)
        }

        @Test("Episode display title")
        func episodeDisplayTitle() {
            let episode = MediaItem(
                id: "ep-1",
                name: "Pilot",
                type: .episode,
                indexNumber: 5,
                parentIndexNumber: 1
            )
            #expect(episode.episodeDisplayTitle == "S01E05 - Pilot")
        }

        @Test("Year span - movies show a plain year")
        func yearSpanMovie() {
            let movie = MediaItem(id: "1", name: "Movie", type: .movie, productionYear: 2024)
            #expect(movie.yearSpanText == "2024")
        }

        @Test("Year span - ended series spans start to end year")
        func yearSpanEndedSeries() {
            let series = MediaItem(
                id: "1", name: "Show", type: .series,
                productionYear: 2008,
                endDate: DateComponents(
                    calendar: Calendar(identifier: .gregorian), year: 2013, month: 9, day: 29
                ).date,
                status: "Ended"
            )
            #expect(series.yearSpanText == "2008–2013")
        }

        @Test("Year span - series ended in its first year shows one year")
        func yearSpanSingleYearSeries() {
            let series = MediaItem(
                id: "1", name: "Show", type: .series,
                productionYear: 2013,
                endDate: DateComponents(
                    calendar: Calendar(identifier: .gregorian), year: 2013, month: 12, day: 1
                ).date,
                status: "Ended"
            )
            #expect(series.yearSpanText == "2013")
        }

        @Test("Year span - continuing series is open-ended")
        func yearSpanContinuingSeries() {
            let series = MediaItem(
                id: "1", name: "Show", type: .series,
                productionYear: 2020, status: "Continuing"
            )
            #expect(series.yearSpanText == "2020–")
        }

        @Test("Season count text pluralizes and skips non-series")
        func seasonCountText() {
            let series = MediaItem(id: "1", name: "Show", type: .series, childCount: 3)
            #expect(series.seasonCountText == "3 Seasons")

            let oneSeason = MediaItem(id: "2", name: "Show", type: .series, childCount: 1)
            #expect(oneSeason.seasonCountText == "1 Season")

            let movie = MediaItem(id: "3", name: "Movie", type: .movie, childCount: 3)
            #expect(movie.seasonCountText == nil)
        }
    }

    @Suite("ParentArtwork Adapter")
    struct ParentArtworkAdapterTests {
        @Test("Maps ancestor backdrop, logo, and series poster tags")
        func mapsAncestorArt() {
            let item = MediaItem(from: BaseItemDto(
                id: "ep1",
                parentBackdropImageTags: ["bd-tag"],
                parentBackdropItemID: "series-1",
                parentLogoImageTag: "logo-tag",
                parentLogoItemID: "series-1",
                seriesID: "series-1",
                seriesPrimaryImageTag: "poster-tag",
                type: .episode
            ))

            #expect(item.parentArtwork?.backdropItemId == "series-1")
            #expect(item.parentArtwork?.backdropImageTag == "bd-tag")
            #expect(item.parentArtwork?.logoItemId == "series-1")
            #expect(item.parentArtwork?.logoImageTag == "logo-tag")
            #expect(item.parentArtwork?.seriesPrimaryImageTag == "poster-tag")
        }

        @Test("Nil when the item inherits no ancestor artwork")
        func nilWithoutAncestorArt() {
            let item = MediaItem(from: BaseItemDto(id: "m1", type: .movie))
            #expect(item.parentArtwork == nil)
        }

        @Test("A tag without its owning item id doesn't count as a fallback")
        func tagWithoutOwnerIsIgnored() {
            let item = MediaItem(from: BaseItemDto(
                id: "ep1",
                parentBackdropImageTags: ["bd-tag"],
                type: .episode
            ))
            #expect(item.parentArtwork == nil)
        }
    }

    @Suite("Person Adapter")
    struct PersonAdapterTests {
        @Test("Maps person items' overloaded dto fields to biographical names")
        func mapsBiographicalFields() {
            let birth = Date(timeIntervalSince1970: 0)
            let death = Date(timeIntervalSince1970: 1_000_000_000)
            let person = Person(from: BaseItemDto(
                endDate: death,
                id: "person-guid",
                imageBlurHashes: BaseItemDto.ImageBlurHashes(primary: ["head-tag": "hash-1"]),
                imageTags: ["Primary": "head-tag"],
                name: "Boris Karloff",
                overview: "An English actor.",
                premiereDate: birth,
                productionLocations: ["London, England, UK", "Elsewhere"],
                type: .person,
                userData: UserItemDataDto(isFavorite: true)
            ))

            #expect(person.id == "person-guid")
            #expect(person.name == "Boris Karloff")
            #expect(person.biography == "An English actor.")
            #expect(person.birthDate == birth)
            #expect(person.deathDate == death)
            #expect(person.birthPlace == "London, England, UK")
            #expect(person.primaryImageTag == "head-tag")
            #expect(person.primaryBlurHash == "hash-1")
            #expect(person.isFavorite)
        }

        @Test("Falls back for missing id, name, and optional fields")
        func fallsBackWhenFieldsMissing() {
            let person = Person(from: BaseItemDto(type: .person))

            #expect(person.id == "")
            #expect(person.name == "Unknown")
            #expect(person.biography == nil)
            #expect(person.birthDate == nil)
            #expect(person.deathDate == nil)
            #expect(person.birthPlace == nil)
            #expect(person.primaryImageTag == nil)
            #expect(person.primaryBlurHash == nil)
            #expect(!person.isFavorite)
        }
    }

    @Suite("Person Model")
    struct PersonModelTests {
        private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }

        @Test("Age at death when a death date is set")
        func ageAtDeath() {
            let person = Person(
                id: "1", name: "P",
                birthDate: date(1887, 11, 23),
                deathDate: date(1969, 2, 2)
            )
            #expect(person.age == 81)
        }

        @Test("Age is nil without a birth date")
        func ageNilWithoutBirthDate() {
            let person = Person(id: "1", name: "P", deathDate: date(1969, 2, 2))
            #expect(person.age == nil)
        }

        @Test("Formatted dates propagate nil")
        func formattedDatesNilPropagation() {
            let person = Person(id: "1", name: "P")
            #expect(person.formattedBirthDate == nil)
            #expect(person.formattedDeathDate == nil)
        }
    }

    @Suite("CastMember Model")
    struct CastMemberModelTests {
        @Test("hasServerId rejects empty and position-fallback ids")
        func hasServerIdDetectsFallbacks() {
            #expect(!CastMember(id: "", name: "A", kind: "Actor").hasServerId)
            #expect(!CastMember(id: "person-3", name: "B", kind: "Actor").hasServerId)
            #expect(CastMember(id: "f4b2c8a1d9e34567", name: "C", kind: "Actor").hasServerId)
        }
    }

    @Suite("MediaTechnicalInfo Adapter")
    struct MediaTechnicalInfoAdapterTests {
        /// Wraps bare streams in a minimal item DTO, the shape most tests need.
        private func info(from streams: [MediaStream]?) -> MediaTechnicalInfo? {
            MediaTechnicalInfo(from: BaseItemDto(mediaSources: streams.map { [MediaSourceInfo(mediaStreams: $0)] }))
        }

        @Test("Distills video, audio, and subtitle streams")
        func distillsStreams() {
            let info = info(from: [
                MediaStream(height: 2160, type: .video, videoRangeType: .doviWithHDR10, width: 3840),
                MediaStream(language: "fra", type: .audio),
                MediaStream(audioSpatialFormat: .dolbyAtmos, channels: 8, isDefault: true, language: "eng", type: .audio),
                MediaStream(language: "eng", type: .subtitle),
                MediaStream(language: "ENG", type: .subtitle),
                MediaStream(isHearingImpaired: true, language: "fra", type: .subtitle)
            ])

            #expect(info?.resolution == "4K")
            #expect(info?.videoRange == "Dolby Vision")
            #expect(info?.audioFormat == "Dolby Atmos")
            // Original audio follows the *default* stream, not the first.
            #expect(info?.originalAudioLanguage == Locale.current.localizedString(forLanguageCode: "eng"))
            #expect(info?.audioLanguages.count == 2)
            #expect(info?.subtitleLanguages.count == 2)
            #expect(info?.hasSubtitles == true)
            #expect(info?.hasSDHSubtitles == true)
        }

        @Test("No SDH flag when no subtitle is hearing-impaired")
        func noSDHWithoutFlaggedStreams() {
            let info = info(from: [
                MediaStream(language: "eng", type: .subtitle)
            ])
            #expect(info?.hasSDHSubtitles == false)
            #expect(info?.hasSubtitles == true)
        }

        @Test("Resolution classes from dimensions")
        func resolutionClasses() {
            func resolution(width: Int, height: Int) -> String? {
                info(from: [
                    MediaStream(height: height, type: .video, width: width)
                ])?.resolution
            }

            #expect(resolution(width: 7680, height: 4320) == "8K")
            #expect(resolution(width: 3840, height: 1600) == "4K")
            #expect(resolution(width: 1920, height: 800) == "1080p")
            #expect(resolution(width: 1280, height: 720) == "720p")
            #expect(resolution(width: 720, height: 480) == "SD")
        }

        @Test("SDR yields no range label; coarse HDR flag is the fallback")
        func videoRangeLabels() {
            let sdr = info(from: [
                MediaStream(type: .video, videoRange: .sdr, videoRangeType: .sdr, width: 1920)
            ])
            #expect(sdr?.videoRange == nil)
            #expect(sdr?.resolution == "1080p")

            let coarseHDR = info(from: [
                MediaStream(type: .video, videoRange: .hdr, width: 3840)
            ])
            #expect(coarseHDR?.videoRange == "HDR")

            let hdr10Plus = info(from: [
                MediaStream(type: .video, videoRangeType: .hdr10Plus, width: 3840)
            ])
            #expect(hdr10Plus?.videoRange == "HDR10+")
        }

        @Test("Audio label prefers the default stream and falls back to channels")
        func audioLabels() {
            let surround = info(from: [
                MediaStream(channels: 2, isDefault: false, type: .audio),
                MediaStream(channels: 6, isDefault: true, type: .audio)
            ])
            #expect(surround?.audioFormat == "5.1")

            let stereo = info(from: [
                MediaStream(channels: 2, type: .audio)
            ])
            #expect(stereo?.audioFormat == "Stereo")
        }

        @Test("Nil when streams are missing or carry nothing displayable")
        func nilWhenEmpty() {
            #expect(info(from: nil) == nil)
            #expect(info(from: []) == nil)
            #expect(info(from: [MediaStream(type: .video)]) == nil)
        }

        @Test("File facts come from the media source")
        func fileFacts() {
            let info = MediaTechnicalInfo(from: BaseItemDto(mediaSources: [
                MediaSourceInfo(
                    bitrate: 24_500_000,
                    container: "mov,mp4,m4a",
                    mediaStreams: [
                        MediaStream(averageFrameRate: 23.976, codec: "hevc", type: .video, width: 3840)
                    ],
                    path: "C:\\Media\\Movies\\Example (2024)\\Example.2024.2160p.mkv",
                    size: 4_200_000_000
                )
            ]))

            #expect(info?.fileName == "Example.2024.2160p.mkv")
            #expect(info?.fileSizeBytes == 4_200_000_000)
            #expect(info?.container == "MOV")
            #expect(info?.videoCodec == "HEVC")
            #expect(info?.bitrate == 24_500_000)
            #expect(info?.frameRate.map { abs($0 - 23.976) < 0.001 } == true)
        }

        @Test("File name falls back to the item path when the source has none")
        func fileNameFallsBackToItemPath() {
            let info = MediaTechnicalInfo(from: BaseItemDto(
                mediaSources: [MediaSourceInfo(mediaStreams: [MediaStream(type: .video, width: 1920)])],
                path: "/media/movies/example.mkv"
            ))
            #expect(info?.fileName == "example.mkv")
        }
    }

    @Suite("Library Model")
    struct LibraryTests {
        @Test("Library initialization")
        func libraryInitialization() {
            let library = Library(
                id: "lib-1",
                name: "Movies",
                collectionType: .movies,
                childCount: 150
            )

            #expect(library.id == "lib-1")
            #expect(library.name == "Movies")
            #expect(library.collectionType == .movies)
            #expect(library.childCount == 150)
        }

        @Test("Library system image names")
        func systemImageNames() {
            let movieLibrary = Library(id: "1", name: "Movies", collectionType: .movies)
            #expect(movieLibrary.systemImageName == "film.fill")

            let tvLibrary = Library(id: "2", name: "TV", collectionType: .tvshows)
            #expect(tvLibrary.systemImageName == "tv.fill")

            let musicLibrary = Library(id: "3", name: "Music", collectionType: .music)
            #expect(musicLibrary.systemImageName == "music.note")
        }
    }

    @Suite("ImageTags Adapter")
    struct ImageTagsAdapterTests {
        @Test("Backdrop falls back to the backdrop tags array")
        func backdropFallsBackToArray() {
            let tags = ImageTags(from: ["Primary": "abc"], backdropTags: ["bd1", "bd2"])
            #expect(tags?.primary == "abc")
            #expect(tags?.backdrop == "bd1")
        }

        @Test("Backdrop dictionary entry wins over the array")
        func backdropDictionaryPrecedence() {
            let tags = ImageTags(from: ["Backdrop": "dict"], backdropTags: ["array"])
            #expect(tags?.backdrop == "dict")
        }

        @Test("Items with only backdrop tags still produce ImageTags")
        func backdropOnly() {
            let tags = ImageTags(from: nil, backdropTags: ["bd1"])
            #expect(tags?.backdrop == "bd1")
            #expect(tags?.primary == nil)
        }

        @Test("Nil when there are no tags at all")
        func nilWhenEmpty() {
            #expect(ImageTags(from: nil, backdropTags: nil) == nil)
            #expect(ImageTags(from: nil, backdropTags: []) == nil)
        }

        @Test("BlurHashes resolve by tag with a first-value fallback")
        func blurHashResolution() {
            let tags = ImageTags(
                from: ["Primary": "p-tag", "Thumb": "t-tag"],
                backdropTags: ["bd-tag"],
                blurHashes: .init(
                    backdrop: ["bd-tag": "bd-hash"],
                    primary: ["other-key": "p-hash"],
                    thumb: [:]
                )
            )

            #expect(tags?.backdropBlurHash == "bd-hash")
            // Tag lookup misses → the type's first hash still applies.
            #expect(tags?.primaryBlurHash == "p-hash")
            // No hashes for the type at all → nil.
            #expect(tags?.thumbBlurHash == nil)
        }

        @Test("MediaItem blurhash conveniences mirror the URL fallback chains")
        func blurHashConveniences() {
            let item = MediaItem(
                id: "1", name: "Movie", type: .movie,
                imageTags: ImageTags(
                    primary: "p", thumb: "t",
                    backdropBlurHash: "bd-hash", thumbBlurHash: "t-hash"
                )
            )
            // No primary hash → poster falls to thumb.
            #expect(item.posterBlurHash == "t-hash")
            #expect(item.backdropBlurHash == "bd-hash")
            #expect(item.landscapeBlurHash == "t-hash")
        }
    }

    @Suite("Image URLs")
    struct ImageURLTests {
        // Qualified: the file imports JellyfinAPI (for adapter tests), which
        // has its own `JellyfinClient`.
        private func makeClient(serverURL: String) -> JellyfinKit.JellyfinClient {
            JellyfinKit.JellyfinClient(
                configuration: JellyfinClientConfiguration(serverURL: URL(string: serverURL)!)
            )
        }

        @Test("Item image URL preserves a server path prefix")
        func itemImageURLPreservesPathPrefix() {
            let client = makeClient(serverURL: "https://demo.jellyfin.org/stable")
            let url = client.getImageURL(itemId: "abc", imageType: .primary, maxWidth: 600, maxHeight: nil)
            #expect(url.absoluteString == "https://demo.jellyfin.org/stable/Items/abc/Images/Primary?maxWidth=600")
        }

        @Test("Item image URL without size parameters")
        func itemImageURLWithoutSize() {
            let client = makeClient(serverURL: "https://jellyfin.example.com")
            let url = client.getImageURL(itemId: "abc", imageType: .backdrop, maxWidth: nil, maxHeight: nil)
            #expect(url.absoluteString == "https://jellyfin.example.com/Items/abc/Images/Backdrop")
        }

        @Test("User image URL")
        func userImageURL() {
            let client = makeClient(serverURL: "https://jellyfin.example.com")
            let url = client.getUserImageURL(userId: "u1", maxWidth: 120)
            #expect(url.absoluteString == "https://jellyfin.example.com/Users/u1/Images/Primary?maxWidth=120")
        }
    }

    @Suite("API Error")
    struct APIErrorTests {
        @Test("Error descriptions")
        func errorDescriptions() {
            #expect(APIError.unauthorized.errorDescription?.contains("Invalid") == true)
            #expect(APIError.notFound.errorDescription?.contains("not found") == true)
            #expect(APIError.notAuthenticated.errorDescription?.contains("Not authenticated") == true)
        }

        @Test("Network error includes message")
        func networkErrorMessage() {
            let error = APIError.networkError("Connection timed out")
            #expect(error.errorDescription?.contains("Connection timed out") == true)
        }
    }

    @Suite("Configuration")
    struct ConfigurationTests {
        @Test("Default configuration values")
        func defaultConfiguration() {
            let url = URL(string: "https://jellyfin.example.com")!
            let config = JellyfinClientConfiguration(serverURL: url)

            #expect(config.serverURL == url)
            #expect(config.clientName == "Jelly Shark")
            #expect(config.clientVersion == "0.0.1")
            #expect(config.deviceName == "Apple TV")
            #expect(!config.deviceID.isEmpty)
        }

        @Test("Custom configuration values")
        func customConfiguration() {
            let url = URL(string: "https://jellyfin.example.com")!
            let config = JellyfinClientConfiguration(
                serverURL: url,
                clientName: "Custom Client",
                clientVersion: "1.0.0",
                deviceName: "Vision Pro",
                deviceID: "custom-id"
            )

            #expect(config.clientName == "Custom Client")
            #expect(config.clientVersion == "1.0.0")
            #expect(config.deviceName == "Vision Pro")
            #expect(config.deviceID == "custom-id")
        }
    }
}

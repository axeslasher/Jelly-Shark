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

    @Suite("MediaTechnicalInfo Adapter")
    struct MediaTechnicalInfoAdapterTests {
        @Test("Distills video, audio, and subtitle streams")
        func distillsStreams() {
            let info = MediaTechnicalInfo(from: [
                MediaStream(height: 2160, type: .video, videoRangeType: .doviWithHDR10, width: 3840),
                MediaStream(audioSpatialFormat: .dolbyAtmos, channels: 8, isDefault: true, type: .audio),
                MediaStream(language: "eng", type: .subtitle),
                MediaStream(language: "ENG", type: .subtitle),
                MediaStream(language: "fra", type: .subtitle)
            ])

            #expect(info?.resolution == "4K")
            #expect(info?.videoRange == "Dolby Vision")
            #expect(info?.audioFormat == "Dolby Atmos")
            #expect(info?.subtitleLanguages.count == 2)
            #expect(info?.hasSubtitles == true)
        }

        @Test("Resolution classes from dimensions")
        func resolutionClasses() {
            func resolution(width: Int, height: Int) -> String? {
                MediaTechnicalInfo(from: [
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
            let sdr = MediaTechnicalInfo(from: [
                MediaStream(type: .video, videoRange: .sdr, videoRangeType: .sdr, width: 1920)
            ])
            #expect(sdr?.videoRange == nil)
            #expect(sdr?.resolution == "1080p")

            let coarseHDR = MediaTechnicalInfo(from: [
                MediaStream(type: .video, videoRange: .hdr, width: 3840)
            ])
            #expect(coarseHDR?.videoRange == "HDR")

            let hdr10Plus = MediaTechnicalInfo(from: [
                MediaStream(type: .video, videoRangeType: .hdr10Plus, width: 3840)
            ])
            #expect(hdr10Plus?.videoRange == "HDR10+")
        }

        @Test("Audio label prefers the default stream and falls back to channels")
        func audioLabels() {
            let info = MediaTechnicalInfo(from: [
                MediaStream(channels: 2, isDefault: false, type: .audio),
                MediaStream(channels: 6, isDefault: true, type: .audio)
            ])
            #expect(info?.audioFormat == "5.1")

            let stereo = MediaTechnicalInfo(from: [
                MediaStream(channels: 2, type: .audio)
            ])
            #expect(stereo?.audioFormat == "Stereo")
        }

        @Test("Nil when streams are missing or carry nothing displayable")
        func nilWhenEmpty() {
            #expect(MediaTechnicalInfo(from: nil) == nil)
            #expect(MediaTechnicalInfo(from: []) == nil)
            #expect(MediaTechnicalInfo(from: [MediaStream(type: .video)]) == nil)
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

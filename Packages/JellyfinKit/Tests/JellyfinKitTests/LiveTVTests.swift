import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

@Suite("Live TV")
struct LiveTVTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func program(channel: String = "c1", from offset: TimeInterval, length: TimeInterval) -> LiveProgram {
        LiveProgram(
            id: "\(channel)-\(offset)",
            channelId: channel,
            name: "Show",
            startDate: start.addingTimeInterval(offset),
            endDate: start.addingTimeInterval(offset + length),
        )
    }

    // MARK: - Adapters

    @Test("A channel maps its number and logo tag")
    func channelAdapter() throws {
        // Field shapes as returned by Jellyfin 10.11.11 `/LiveTv/Channels`
        // for an M3U tuner, observed 2026-11-11.
        let dto = BaseItemDto(
            channelNumber: "4",
            id: "ch4",
            imageTags: ["Primary": "tag4"],
            name: "Star Trek",
            type: .tvChannel,
        )
        let channel = try #require(LiveChannel(from: dto))
        #expect(channel == LiveChannel(id: "ch4", name: "Star Trek", number: "4", imageTag: "tag4"))
    }

    @Test("A channel becomes a playable item under its own id")
    func channelAsMediaItem() {
        let item = LiveChannel(id: "ch4", name: "Star Trek", number: "4", imageTag: "tag4").asMediaItem
        #expect(item.id == "ch4")
        #expect(item.type == .tvChannel)
        #expect(item.imageTags?.primary == "tag4")
        #expect(item.runTimeTicks == nil)
    }

    @Test("A programme maps its schedule, episode line and artwork")
    func programAdapter() throws {
        let dto = BaseItemDto(
            channelID: "ch4",
            endDate: start.addingTimeInterval(3000),
            episodeTitle: "Errand of Mercy",
            genres: ["Science Fiction"],
            id: "p1",
            imageTags: ["Primary": "ptag"],
            indexNumber: 26,
            name: "Star Trek",
            officialRating: "TV-PG",
            overview: "Kirk and Spock go undercover.",
            parentIndexNumber: 1,
            productionYear: 1967,
            startDate: start,
        )
        let program = try #require(LiveProgram(from: dto))
        #expect(program.channelId == "ch4")
        #expect(program.name == "Star Trek")
        #expect(program.episodeTitle == "Errand of Mercy")
        #expect(program.seasonNumber == 1)
        #expect(program.episodeNumber == 26)
        #expect(program.genres == ["Science Fiction"])
        #expect(program.officialRating == "TV-PG")
        #expect(program.imageTag == "ptag")
        // An XMLTV guide supplies one image, so landscape art is absent
        #expect(program.thumbImageTag == nil)
        #expect(program.backdropImageTag == nil)
        #expect(program.endDate.timeIntervalSince(program.startDate) == 3000)
        #expect(program.productionYear == 1967)
        #expect(program.formattedRuntime == MediaItem.runtimeText(50 * 60 * 10_000_000))
    }

    @Test("A programme maps landscape artwork when the guide source supplies it")
    func programAdapterLandscapeArt() throws {
        let dto = BaseItemDto(
            backdropImageTags: ["btag", "second"],
            channelID: "ch4",
            endDate: start.addingTimeInterval(60),
            id: "p1",
            imageTags: ["Primary": "ptag", "Thumb": "ttag"],
            startDate: start,
        )
        let program = try #require(LiveProgram(from: dto))
        #expect(program.imageTag == "ptag")
        #expect(program.thumbImageTag == "ttag")
        #expect(program.backdropImageTag == "btag")
    }

    @Test("A programme that cannot be placed on the guide is dropped")
    func programAdapterRejectsUnplaceable() {
        let noChannel = BaseItemDto(endDate: start.addingTimeInterval(60), id: "p", startDate: start)
        let noEnd = BaseItemDto(channelID: "c", id: "p", startDate: start)
        let backwards = BaseItemDto(channelID: "c", endDate: start, id: "p", startDate: start.addingTimeInterval(60))
        #expect(LiveProgram(from: noChannel) == nil)
        #expect(LiveProgram(from: noEnd) == nil)
        #expect(LiveProgram(from: backwards) == nil)
    }

    // MARK: - Schedule maths

    @Test("Back-to-back programmes never both claim the changeover instant")
    func airingIsEndExclusive() {
        let first = program(from: 0, length: 600)
        let second = program(from: 600, length: 600)
        let changeover = start.addingTimeInterval(600)
        #expect(!first.isAiring(at: changeover))
        #expect(second.isAiring(at: changeover))
        #expect([first, second].airing(at: changeover, onChannel: "c1") == second)
    }

    @Test("The airing lookup is per channel and nil in a gap")
    func airingLookup() {
        let programs = [program(channel: "c1", from: 0, length: 600), program(channel: "c2", from: 0, length: 600)]
        #expect(programs.airing(at: start.addingTimeInterval(10), onChannel: "c2")?.channelId == "c2")
        #expect(programs.airing(at: start.addingTimeInterval(700), onChannel: "c1") == nil)
        #expect(programs.airing(at: start, onChannel: "c3") == nil)
    }

    @Test("Progress runs from 0 to 1 and clamps outside the programme")
    func progress() {
        let show = program(from: 0, length: 1000)
        #expect(show.progress(at: start.addingTimeInterval(250)) == 0.25)
        #expect(show.progress(at: start.addingTimeInterval(-50)) == 0)
        #expect(show.progress(at: start.addingTimeInterval(5000)) == 1)
    }

    // MARK: - Stream negotiation

    @Test("The live profile offers no direct play, and HLS in TS segments only")
    func liveProfile() throws {
        // With any direct-play claim the server answers with the tuner's raw
        // address; offered MP4 segments it answers with a progressive file
        // AVPlayer stops on (both observed 2026-11-11, 10.11.11 + M3U tuner).
        let base = JellyfinAPI.DeviceProfile(capabilities: .jellySharkAVFoundationFixture)
        let live = JellyfinAPI.DeviceProfile(liveCapabilities: .jellySharkAVFoundationFixture)
        #expect(base.directPlayProfiles?.isEmpty == false)
        #expect(live.directPlayProfiles?.isEmpty == true)

        let transcoding = try #require(live.transcodingProfiles?.first)
        #expect(live.transcodingProfiles?.count == 1)
        #expect(transcoding.protocol == .hls)
        #expect(transcoding.container == "ts")
        #expect(transcoding.videoCodec == "h264")
        // Everything else is the engine's own declaration
        let baseTranscoding = try #require(base.transcodingProfiles?.first)
        #expect(transcoding.audioCodec == baseTranscoding.audioCodec)
        #expect(transcoding.minSegments == baseTranscoding.minSegments)
        #expect(live.codecProfiles == base.codecProfiles)
        // The library profile is untouched
        #expect(baseTranscoding.container != "ts")
    }

    @Test(
        "The server-relative stream path joins onto the server address",
        arguments: [
            ("http://localhost:8096", "http://localhost:8096/videos/abc/master.m3u8?ApiKey=k&LiveStreamId=x_y"),
            ("http://localhost:8096/", "http://localhost:8096/videos/abc/master.m3u8?ApiKey=k&LiveStreamId=x_y"),
            ("https://tv.example.com/jellyfin", "https://tv.example.com/jellyfin/videos/abc/master.m3u8?ApiKey=k&LiveStreamId=x_y"),
        ],
    )
    func streamURL(server: String, expected: String) throws {
        let serverURL = try #require(URL(string: server))
        let url = LiveStreamURL.resolve(serverURL: serverURL, path: "/videos/abc/master.m3u8?ApiKey=k&LiveStreamId=x_y")
        #expect(url?.absoluteString == expected)
    }

    // MARK: - Registry

    @Test("Reports for a live session find its stream id until it is forgotten")
    func registry() throws {
        let registry = LiveStreamRegistry()
        let url = try #require(URL(string: "http://localhost/x"))
        let session = LiveStreamSession(
            url: url,
            playSessionId: "play1",
            mediaSourceId: "src",
            liveStreamId: "live1",
        )
        #expect(registry.liveStreamId(forPlaySession: "play1") == nil)
        registry.register(session)
        #expect(registry.liveStreamId(forPlaySession: "play1") == "live1")
        // A library item's session, and a report with no session at all
        #expect(registry.liveStreamId(forPlaySession: "other") == nil)
        #expect(registry.liveStreamId(forPlaySession: nil) == nil)
        registry.forget(playSession: "play1")
        #expect(registry.liveStreamId(forPlaySession: "play1") == nil)
    }

    @Test("A stopped report that fails still forgets the live session")
    func stoppedReportFailureForgetsSession() async throws {
        // Nothing listens on port 1, so the report is refused at once. The
        // session is over either way, and an entry left behind would tag a
        // later report that reused the play session id.
        let server = try #require(URL(string: "http://127.0.0.1:1"))
        let client = JellyfinClient(configuration: JellyfinClientConfiguration(serverURL: server))
        let url = try #require(URL(string: "http://127.0.0.1:1/x"))
        client.liveStreams.register(LiveStreamSession(url: url, playSessionId: "play1", mediaSourceId: "src", liveStreamId: "live1"))

        await #expect(throws: (any Error).self) {
            try await client.reportPlaybackStopped(itemId: "ch4", mediaSourceId: "src", playSessionId: "play1", positionTicks: 0)
        }

        #expect(client.liveStreams.liveStreamId(forPlaySession: "play1") == nil)
    }
}

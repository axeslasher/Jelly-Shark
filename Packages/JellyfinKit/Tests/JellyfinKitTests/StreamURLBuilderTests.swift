import Foundation
@testable import JellyfinKit
import Testing

@Suite("StreamURLBuilder")
struct StreamURLBuilderTests {
    private func queryItems(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var result: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }

    @Test("HLS URL targets the master playlist")
    func hlsPath() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token-123",
            deviceId: "device-abc",
            parameters: StreamParameters(itemId: "item-1"),
        ))

        // master.m3u8, not main.m3u8: only the master playlist advertises
        // subtitle renditions
        #expect(url.path == "/Videos/item-1/master.m3u8")
    }

    @Test("HLS URL includes required query parameters")
    func requiredQueryParameters() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token-123",
            deviceId: "device-abc",
            parameters: StreamParameters(
                itemId: "item-1",
                mediaSourceId: "source-1",
                playSessionId: "session-1",
            ),
        ))

        let query = queryItems(of: url)
        #expect(query["api_key"] == "token-123")
        #expect(query["DeviceId"] == "device-abc")
        #expect(query["MediaSourceId"] == "source-1")
        #expect(query["PlaySessionId"] == "session-1")
        #expect(query["VideoCodec"] == "hevc,h264")
        #expect(query["AudioCodec"] == "aac,ac3,eac3")
        // ts, not mp4: fMP4 segments desync Jellyfin's VTT time map by 10s
        #expect(query["SegmentContainer"] == "ts")
        #expect(query["SubtitleMethod"] == "Hls")
        #expect(query["VideoBitrate"] == String(JellyfinClient.maxStreamingBitrate - StreamURLBuilder.audioBitrate))
        #expect(query["AudioBitrate"] == String(StreamURLBuilder.audioBitrate))
    }

    @Test("Subtitle delivery method is reflected in the query")
    func subtitleMethodVariants() throws {
        let encode = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1", subtitleStreamIndex: 2),
            subtitleMethod: .encode,
        ))
        #expect(queryItems(of: encode)["SubtitleMethod"] == "Encode")

        let hls = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1", subtitleStreamIndex: 2),
            subtitleMethod: .hls,
        ))
        #expect(queryItems(of: hls)["SubtitleMethod"] == "Hls")
    }

    @Test("Stream indices are omitted when nil")
    func streamIndicesOmitted() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1"),
        ))

        let query = queryItems(of: url)
        #expect(query["AudioStreamIndex"] == nil)
        #expect(query["SubtitleStreamIndex"] == nil)
        #expect(query["Tag"] == nil)
    }

    @Test("Stream indices and tag are included when set")
    func streamIndicesIncluded() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(
                itemId: "item-1",
                audioStreamIndex: 1,
                subtitleStreamIndex: 3,
            ),
            eTag: "etag-9",
        ))

        let query = queryItems(of: url)
        #expect(query["AudioStreamIndex"] == "1")
        #expect(query["SubtitleStreamIndex"] == "3")
        #expect(query["Tag"] == "etag-9")
    }

    @Test("Server path prefix is preserved")
    func serverPathPrefixPreserved() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com/jellyfin")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1"),
        ))

        #expect(url.path == "/jellyfin/Videos/item-1/master.m3u8")
    }

    // MARK: - Direct play

    @Test("Direct-play URL targets the static endpoint with the container extension")
    func directPlayPath() throws {
        let url = try #require(StreamURLBuilder.directPlayURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token-123",
            deviceId: "device-abc",
            parameters: StreamParameters(
                itemId: "item-1",
                mediaSourceId: "source-1",
                playSessionId: "session-1",
            ),
            container: "mp4",
            eTag: "etag-9",
        ))

        #expect(url.path == "/Videos/item-1/stream.mp4")
        let query = queryItems(of: url)
        #expect(query["static"] == "true")
        #expect(query["api_key"] == "token-123")
        #expect(query["DeviceId"] == "device-abc")
        #expect(query["MediaSourceId"] == "source-1")
        #expect(query["PlaySessionId"] == "session-1")
        #expect(query["Tag"] == "etag-9")
    }

    @Test("Direct-play URL omits stream selection and transcode parameters")
    func directPlayOmitsStreamSelection() throws {
        let url = try #require(StreamURLBuilder.directPlayURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(
                itemId: "item-1",
                audioStreamIndex: 1,
                subtitleStreamIndex: 3,
            ),
        ))

        let query = queryItems(of: url)
        #expect(query["AudioStreamIndex"] == nil)
        #expect(query["SubtitleStreamIndex"] == nil)
        #expect(query["VideoCodec"] == nil)
        #expect(query["AudioCodec"] == nil)
        #expect(query["TranscodingProtocol"] == nil)
    }

    @Test("Container extension is skipped when unknown or a list")
    func directPlayContainerExtension() throws {
        let bare = try #require(StreamURLBuilder.directPlayURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1"),
            container: nil,
        ))
        #expect(bare.path == "/Videos/item-1/stream")

        let list = try #require(StreamURLBuilder.directPlayURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1"),
            container: "mov,mp4,m4a",
        ))
        #expect(list.path == "/Videos/item-1/stream")
    }

    @Test("Direct-play URL preserves the server path prefix")
    func directPlayPathPrefixPreserved() throws {
        let url = try #require(StreamURLBuilder.directPlayURL(
            serverURL: URL(string: "https://example.com/jellyfin")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1"),
            container: "mp4",
        ))

        #expect(url.path == "/jellyfin/Videos/item-1/stream.mp4")
    }
}

@Suite("PlayMethod Decision")
struct PlayMethodDecisionTests {
    private func source(
        directPlay: Bool,
        directStream: Bool,
        defaultAudioStreamIndex: Int? = 1,
        subtitleStreams: [MediaStreamInfo] = [],
    ) -> MediaSource {
        MediaSource(
            id: "source-1",
            container: "mp4",
            supportsDirectPlay: directPlay,
            supportsDirectStream: directStream,
            supportsTranscoding: true,
            defaultAudioStreamIndex: defaultAudioStreamIndex,
            subtitleStreams: subtitleStreams,
        )
    }

    @Test("Direct-play-capable source with default tracks direct plays")
    func directPlayWithDefaults() {
        let source = source(directPlay: true, directStream: true)
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: nil) == .directPlay)
        #expect(source.playMethod(audioStreamIndex: 1, subtitleStreamIndex: nil) == .directPlay)
    }

    @Test("Non-default audio routes through HLS")
    func nonDefaultAudioFallsBack() {
        let source = source(directPlay: true, directStream: true)
        #expect(source.playMethod(audioStreamIndex: 2, subtitleStreamIndex: nil) == .directStream)
    }

    @Test("Any subtitle selection routes through HLS")
    func subtitleSelectionFallsBack() {
        let source = source(directPlay: true, directStream: true)
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: 3) == .directStream)
        #expect(source.playMethod(audioStreamIndex: 1, subtitleStreamIndex: 3) == .directStream)
    }

    @Test("Direct-stream-only sources direct stream")
    func directStreamOnly() {
        let source = source(directPlay: false, directStream: true)
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: nil) == .directStream)
    }

    @Test("Sources supporting neither transcode")
    func neitherTranscodes() {
        let source = source(directPlay: false, directStream: false)
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: nil) == .transcode)
        #expect(source.playMethod(audioStreamIndex: 2, subtitleStreamIndex: 3) == .transcode)
    }

    @Test("Image subtitle selection forces a transcode for burn-in")
    func imageSubtitleBurnsIn() {
        let source = source(
            directPlay: true,
            directStream: true,
            subtitleStreams: [
                MediaStreamInfo(index: 2, type: .subtitle, codec: "pgssub", isTextSubtitleStream: false),
                MediaStreamInfo(index: 3, type: .subtitle, codec: "subrip", isTextSubtitleStream: true),
            ],
        )
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: 2) == .transcode)
        #expect(source.subtitleRequiresBurnIn(at: 2))
    }

    @Test("Text subtitle selection remuxes rather than transcodes")
    func textSubtitleRemuxes() {
        let source = source(
            directPlay: true,
            directStream: true,
            subtitleStreams: [
                MediaStreamInfo(index: 3, type: .subtitle, codec: "subrip", isTextSubtitleStream: true),
            ],
        )
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: 3) == .directStream)
        #expect(!source.subtitleRequiresBurnIn(at: 3))
    }

    @Test("Unknown subtitle index is treated as text")
    func unknownSubtitleIndexFallsBackToText() {
        let source = source(directPlay: true, directStream: true)
        #expect(source.playMethod(audioStreamIndex: nil, subtitleStreamIndex: 9) == .directStream)
        #expect(!source.subtitleRequiresBurnIn(at: 9))
        #expect(!source.subtitleRequiresBurnIn(at: nil))
    }
}

@Suite("PlaybackTicks")
struct PlaybackTicksTests {
    @Test("Ticks to seconds")
    func ticksToSeconds() {
        // 2 hours
        #expect(PlaybackTicks.seconds(fromTicks: 72_000_000_000) == 7200)
    }

    @Test("Seconds to ticks")
    func secondsToTicks() {
        #expect(PlaybackTicks.ticks(fromSeconds: 7200) == 72_000_000_000)
    }

    @Test("Round trip")
    func roundTrip() {
        let ticks: Int64 = 1_234_567_890
        #expect(PlaybackTicks.ticks(fromSeconds: PlaybackTicks.seconds(fromTicks: ticks)) == ticks)
    }

    @Test("Zero")
    func zero() {
        #expect(PlaybackTicks.seconds(fromTicks: 0) == 0)
        #expect(PlaybackTicks.ticks(fromSeconds: 0) == 0)
    }

    @Test("Sub-second precision")
    func subSecondPrecision() {
        // Half a second = 5,000,000 ticks
        #expect(PlaybackTicks.ticks(fromSeconds: 0.5) == 5_000_000)
        #expect(PlaybackTicks.seconds(fromTicks: 5_000_000) == 0.5)
    }
}

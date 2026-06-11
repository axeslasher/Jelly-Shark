import Testing
import Foundation
@testable import JellyfinKit

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

    @Test("HLS URL has the universal endpoint path")
    func hlsPath() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token-123",
            deviceId: "device-abc",
            parameters: StreamParameters(itemId: "item-1")
        ))

        #expect(url.path == "/Videos/item-1/main.m3u8")
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
                playSessionId: "session-1"
            )
        ))

        let query = queryItems(of: url)
        #expect(query["api_key"] == "token-123")
        #expect(query["DeviceId"] == "device-abc")
        #expect(query["MediaSourceId"] == "source-1")
        #expect(query["PlaySessionId"] == "session-1")
        #expect(query["VideoCodec"] == "hevc,h264")
        #expect(query["AudioCodec"] == "aac,ac3,eac3")
        #expect(query["SubtitleMethod"] == "Hls")
    }

    @Test("Stream indices are omitted when nil")
    func streamIndicesOmitted() throws {
        let url = try #require(StreamURLBuilder.hlsURL(
            serverURL: URL(string: "https://example.com")!,
            accessToken: "token",
            deviceId: "device",
            parameters: StreamParameters(itemId: "item-1")
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
                subtitleStreamIndex: 3
            ),
            eTag: "etag-9"
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
            parameters: StreamParameters(itemId: "item-1")
        ))

        #expect(url.path == "/jellyfin/Videos/item-1/main.m3u8")
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

@testable import Features
import Foundation
import JellyfinKit
import Testing

/// Stands in for the Jellyfin origin inside the server's URLSession.
/// Responses are keyed by URL-path suffix; unmatched requests fail as if
/// the origin were unreachable.
private final class StubOriginProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let body = Self.responses.first(where: { path.hasSuffix($0.key) })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/vnd.apple.mpegurl"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Refuses redirects so the test can observe the 302 itself
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
    ) async -> URLRequest? {
        nil
    }
}

// Serialized: every test shares the StubOriginProtocol response table, and
// the subtitle cases depend on it persisting across two sequential requests
@Suite(.serialized)
struct PlaybackLocalServerTests {
    private let originURL = URL(string: "https://origin.example/Videos/item-1/master.m3u8")!

    private let sampleInfo = TrickplayInfo(
        widthKey: 320, thumbnailWidth: 320, thumbnailHeight: 180,
        columns: 10, rows: 10, intervalMilliseconds: 10000, thumbnailCount: 60,
    )

    private func makeServer(info: TrickplayInfo?) -> PlaybackLocalServer {
        PlaybackLocalServer(
            originalMasterURL: originURL,
            info: info,
            tileURL: { _ in nil },
            protocolClasses: [StubOriginProtocol.self],
        )
    }

    private func get(_ path: String, from base: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession(configuration: .ephemeral)
            .data(for: request, delegate: NoRedirectDelegate())
        return try (data, #require(response as? HTTPURLResponse))
    }

    /// The failure mode that used to crash MediaToolbox: the origin answers
    /// the master request with a *media* playlist. The server must refuse to
    /// interpose and bounce the player to the origin instead — a media
    /// playlist carries no subtitle renditions, so the redirect is safe and
    /// playback survives with thumbnails given up.
    @Test("A media playlist from the origin degrades to a 302 back to origin")
    func mediaPlaylistRedirectsToOrigin() async throws {
        StubOriginProtocol.responses = ["master.m3u8": Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg0.ts
        #EXT-X-ENDLIST
        """.utf8)]

        let server = makeServer(info: sampleInfo)
        defer { server.stop() }
        let localURL = try #require(await server.start())

        let (_, http) = try await get("master.m3u8", from: localURL)
        #expect(http.statusCode == 302)
        #expect(http.value(forHTTPHeaderField: "Location") == originURL.absoluteString)
    }

    @Test("An unreachable origin answers 502, not a silent redirect")
    func masterFetchFailureIsLoud() async throws {
        StubOriginProtocol.responses = [:]

        let server = makeServer(info: sampleInfo)
        defer { server.stop() }
        let localURL = try #require(await server.start())

        let (_, http) = try await get("master.m3u8", from: localURL)
        #expect(http.statusCode == 502)
    }

    @Test("Subtitle renditions round-trip through the local subs route")
    func subtitlePlaylistIsProxiedAndRewritten() async throws {
        StubOriginProtocol.responses = [
            "master.m3u8": Data("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="item-1/source-1/Subtitles/2/subtitles.m3u8?SegmentLength=30&ApiKey=tok",LANGUAGE="eng"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"
            main.m3u8
            """.utf8),
            "subtitles.m3u8": Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:30
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:30,
            stream.vtt?CopyTimestamps=true&AddVttTimeMap=true&StartPositionTicks=0&EndPositionTicks=300000000&ApiKey=tok
            #EXT-X-ENDLIST
            """.utf8),
        ]

        let server = makeServer(info: nil)
        defer { server.stop() }
        let localURL = try #require(await server.start())

        let (masterData, masterResponse) = try await get("master.m3u8", from: localURL)
        let master = String(decoding: masterData, as: UTF8.self)
        #expect(masterResponse.statusCode == 200)
        #expect(master.contains("URI=\"/subs/0.m3u8\""))
        // No trickplay data: nothing appended, image rendition still dropped
        #expect(!master.contains("EXT-X-I-FRAME-STREAM-INF"))

        let (subsData, subsResponse) = try await get("subs/0.m3u8", from: localURL)
        let subs = String(decoding: subsData, as: UTF8.self)
        #expect(subsResponse.statusCode == 200)
        #expect(!subs.contains("AddVttTimeMap"))
        #expect(subs.contains(
            "https://origin.example/Videos/item-1/item-1/source-1/Subtitles/2/stream.vtt?"
                + "CopyTimestamps=true&StartPositionTicks=0&EndPositionTicks=300000000&ApiKey=tok",
        ))
    }

    @Test("A failed subtitle playlist fetch answers 502")
    func subtitleFetchFailureIsLoud() async throws {
        StubOriginProtocol.responses = [
            "master.m3u8": Data("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="item-1/Subtitles/2/subtitles.m3u8?ApiKey=tok"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"
            main.m3u8
            """.utf8),
        ]

        let server = makeServer(info: nil)
        defer { server.stop() }
        let localURL = try #require(await server.start())

        _ = try await get("master.m3u8", from: localURL)
        let (_, http) = try await get("subs/0.m3u8", from: localURL)
        #expect(http.statusCode == 502)
    }

    @Test("Trickplay routes 404 when the session has no trickplay data")
    func trickplayRoutesRequireInfo() async throws {
        StubOriginProtocol.responses = [:]

        let server = makeServer(info: nil)
        defer { server.stop() }
        let localURL = try #require(await server.start())

        let (_, iframe) = try await get("iframe.m3u8", from: localURL)
        let (_, initSegment) = try await get("init.mp4", from: localURL)
        #expect(iframe.statusCode == 404)
        #expect(initSegment.statusCode == 404)
    }
}

@testable import Features
import Foundation
import JellyfinKit
import Testing

/// Stands in for the Jellyfin origin inside the server's URLSession
private final class StubOriginProtocol: URLProtocol {
    nonisolated(unsafe) static var masterBody = Data()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/vnd.apple.mpegurl"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.masterBody)
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

struct TrickplayLocalServerTests {
    /// The failure mode that used to crash MediaToolbox: the origin answers
    /// the master request with a *media* playlist. The server must refuse to
    /// interpose and bounce the player to the origin instead — playback
    /// survives, thumbnails are given up.
    @Test("A media playlist from the origin degrades to a 302 back to origin")
    func mediaPlaylistRedirectsToOrigin() async throws {
        let originURL = URL(string: "https://origin.example/Videos/item-1/master.m3u8")!
        StubOriginProtocol.masterBody = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg0.ts
        #EXT-X-ENDLIST
        """.utf8)

        let server = TrickplayLocalServer(
            originalMasterURL: originURL,
            info: TrickplayInfo(
                widthKey: 320, thumbnailWidth: 320, thumbnailHeight: 180,
                columns: 10, rows: 10, intervalMilliseconds: 10000, thumbnailCount: 60,
            ),
            tileURL: { _ in nil },
            protocolClasses: [StubOriginProtocol.self],
        )
        defer { server.stop() }

        let localURL = try #require(await server.start())
        var request = URLRequest(url: localURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await URLSession(configuration: .ephemeral)
            .data(for: request, delegate: NoRedirectDelegate())
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 302)
        #expect(http.value(forHTTPHeaderField: "Location") == originURL.absoluteString)
    }
}

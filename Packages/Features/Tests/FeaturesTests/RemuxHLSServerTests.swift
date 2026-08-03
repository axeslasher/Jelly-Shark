@testable import Features
import Foundation
@testable import JellyfinKit
import Testing

/// The remux HLS server's HTTP contract, exercised over a real loopback
/// listener with URLSession — the same protocol AVPlayer speaks. The
/// progressive predecessor's first device round failed with the player
/// seeing zero bytes and the server logging nothing; this suite is where
/// that class of bug must fail first.
@Suite("RemuxHLSServer HTTP")
struct RemuxHLSServerTests {
    private func makeServer() async throws -> (RemuxHLSServer, URL, HLSSegmentPlan, Data) {
        let fixtureURL = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: fixtureURL)))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)
        let firstEnd = index.cues.count > 1 ? index.cues[1].clusterOffset : index.segmentDataEnd
        let firstSpan = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: firstEnd)
        let initSegment = try remuxer.makeInitializationSegment(firstCluster: firstSpan)
        let plan = HLSSegmentPlan(index: index, timescale: remuxer.timescale)

        let server = RemuxHLSServer(demuxer: demuxer, remuxer: remuxer, plan: plan, initSegment: initSegment)
        let url = try #require(await server.start())
        return (server, url, plan, initSegment)
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return try (data, #require(response as? HTTPURLResponse))
    }

    /// Resolve a playlist-relative URI the way AVPlayer does.
    private func resolved(_ path: String, against playlistURL: URL) throws -> URL {
        try #require(URL(string: path, relativeTo: playlistURL))
    }

    @Test("The playlist is served verbatim with the HLS content type")
    func playlist() async throws {
        let (server, url, plan, _) = try await makeServer()
        defer { server.stop() }

        let (data, response) = try await get(url)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(String(decoding: data, as: UTF8.self) == plan.mediaPlaylist())
    }

    @Test("The init segment resolves relative to the playlist and is byte-exact")
    func initSegment() async throws {
        let (server, url, _, initSegment) = try await makeServer()
        defer { server.stop() }

        let (data, response) = try await get(resolved(HLSSegmentPlan.initSegmentPath, against: url))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(data == initSegment)
        #expect(String(decoding: data.subdata(in: 4 ..< 8), as: UTF8.self) == "ftyp")
    }

    @Test("Every planned segment serves as styp + moof + mdat")
    func segments() async throws {
        let (server, url, plan, _) = try await makeServer()
        defer { server.stop() }

        for index in plan.segments.indices {
            let (data, response) = try await get(resolved(HLSSegmentPlan.segmentPath(index), against: url))
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Content-Type") == "video/iso.segment")
            // ffmpeg's device-verified segment shape leads with styp.
            #expect(String(decoding: data.subdata(in: 4 ..< 8), as: UTF8.self) == "styp")
            #expect(String(decoding: data.subdata(in: 28 ..< 32), as: UTF8.self) == "moof")
        }
    }

    @Test("A re-requested segment is served from cache, byte-identical")
    func segmentReRequest() async throws {
        let (server, url, _, _) = try await makeServer()
        defer { server.stop() }

        let segmentURL = try resolved(HLSSegmentPlan.segmentPath(0), against: url)
        let (first, _) = try await get(segmentURL)
        let (second, _) = try await get(segmentURL)
        #expect(first == second)
    }

    @Test("Unknown paths and out-of-range segments 404")
    func errorPaths() async throws {
        let (server, url, plan, _) = try await makeServer()
        defer { server.stop() }

        let (_, notFound) = try await get(resolved("other.mp4", against: url))
        #expect(notFound.statusCode == 404)

        let (_, outOfRange) = try await get(resolved(HLSSegmentPlan.segmentPath(plan.segments.count), against: url))
        #expect(outOfRange.statusCode == 404)
    }
}

@testable import Features
import Foundation
@testable import JellyfinKit
import Testing

/// The progressive server's HTTP contract, exercised over a real loopback
/// listener with URLSession — the same protocol AVPlayer speaks. The
/// 2026-08-02 device run failed with the player seeing zero bytes and the
/// server logging nothing; this suite is where that class of bug must fail
/// first.
@Suite("ProgressiveRemuxServer HTTP")
struct ProgressiveRemuxServerTests {
    private func makeServer() async throws -> (ProgressiveRemuxServer, URL, ProgressiveMP4Layout) {
        let fixtureURL = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: fixtureURL)))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)
        let firstEnd = index.cues.count > 1 ? index.cues[1].clusterOffset : index.segmentDataEnd
        let firstSpan = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: firstEnd)
        let initSegment = try remuxer.makeInitializationSegment(firstCluster: firstSpan)
        let layout = ProgressiveMP4Layout(index: index, initSegment: initSegment, timescale: remuxer.timescale, trackIDs: remuxer.trackIDs)

        let server = ProgressiveRemuxServer(demuxer: demuxer, remuxer: remuxer, layout: layout)
        let url = try #require(await server.start())
        return (server, url, layout)
    }

    private func get(_ url: URL, range: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return try (data, #require(response as? HTTPURLResponse))
    }

    @Test("The probe range AVPlayer opens with answers 206 with Content-Range")
    func probeRange() async throws {
        let (server, url, layout) = try await makeServer()
        defer { server.stop() }

        let (data, response) = try await get(url, range: "bytes=0-1")
        #expect(response.statusCode == 206)
        #expect(data.count == 2)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 0-1/\(layout.totalSize)")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(data == layout.head.prefix(2))
    }

    @Test("The head range returns ftyp + moov + sidx bytes exactly")
    func headRange() async throws {
        let (server, url, layout) = try await makeServer()
        defer { server.stop() }

        let headSize = layout.initSegment.count + layout.sidx.count
        let (data, response) = try await get(url, range: "bytes=0-\(headSize - 1)")
        #expect(response.statusCode == 206)
        #expect(data == layout.head)
    }

    @Test("A range spanning head and first fragment stitches correctly")
    func straddlingRange() async throws {
        let (server, url, layout) = try await makeServer()
        defer { server.stop() }

        let headSize = layout.initSegment.count + layout.sidx.count
        let (data, response) = try await get(url, range: "bytes=\(headSize - 16)-\(headSize + 255)")
        #expect(response.statusCode == 206)
        #expect(data.count == 272)
        #expect(data.prefix(16) == layout.head.suffix(16))
        // The fragment bytes must start with a moof box header.
        #expect(String(decoding: data.dropFirst(16).dropFirst(4).prefix(4), as: UTF8.self) == "moof")
    }

    @Test("An open-ended tail range serves the last fragment's padding")
    func tailRange() async throws {
        let (server, url, layout) = try await makeServer()
        defer { server.stop() }

        let (data, response) = try await get(url, range: "bytes=\(layout.totalSize - 1024)-")
        #expect(response.statusCode == 206)
        #expect(data.count == 1024)
    }

    @Test("A full unranged GET streams the entire virtual file")
    func fullFile() async throws {
        let (server, url, layout) = try await makeServer()
        defer { server.stop() }

        let (data, response) = try await get(url, range: nil)
        #expect(response.statusCode == 200)
        #expect(UInt64(data.count) == layout.totalSize)
        // Structure: ftyp, moov, sidx, then moof/mdat pairs.
        #expect(String(decoding: data.subdata(in: 4 ..< 8), as: UTF8.self) == "ftyp")
    }

    @Test("Unknown paths 404 and unsatisfiable ranges 416")
    func errorPaths() async throws {
        let (server, url, layout) = try await makeServer()
        defer { server.stop() }

        var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.path = "/other.mp4"
        let (_, notFound) = try await get(#require(components.url), range: nil)
        #expect(notFound.statusCode == 404)

        let (_, unsatisfiable) = try await get(url, range: "bytes=\(layout.totalSize)-")
        #expect(unsatisfiable.statusCode == 416)
    }
}

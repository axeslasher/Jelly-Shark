import Foundation
@testable import JellyfinKit
import Testing

@Suite("HLSSegmentPlan")
struct HLSSegmentPlanTests {
    /// Plan over the real ffmpeg fixture: index, remuxer timescale.
    private func makePlan() async throws -> (MatroskaIndex, HLSSegmentPlan) {
        let url = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: url)))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)
        return (index, HLSSegmentPlan(index: index, timescale: remuxer.timescale))
    }

    @Test("Segments tile the cue spans contiguously")
    func segmentsTileCueSpans() async throws {
        let (index, plan) = try await makePlan()
        #expect(plan.segments.count == index.cues.count)
        for (i, segment) in plan.segments.enumerated() {
            #expect(segment.clusterOffset == index.cues[i].clusterOffset)
            let expectedEnd = i + 1 < index.cues.count ? index.cues[i + 1].clusterOffset : index.segmentDataEnd
            #expect(segment.clusterEndBound == expectedEnd)
        }
    }

    @Test("Durations come from cue gaps and sum to the source duration")
    func durations() async throws {
        let (index, plan) = try await makePlan()
        for segment in plan.segments {
            #expect(segment.durationSeconds > 0)
        }
        let total = plan.segments.map(\.durationSeconds).reduce(0, +)
        let declared = try #require(index.durationSeconds)
        #expect(abs(total - declared) < 0.01)
    }

    @Test("The media playlist is a master-less ffmpeg-shaped VOD playlist")
    func mediaPlaylist() async throws {
        let (_, plan) = try await makePlan()
        let lines = plan.mediaPlaylist().split(separator: "\n").map(String.init)

        // The header, in ffmpeg's exact order — the shape the 2026-08-02
        // device round verified against the eligibility gate.
        #expect(Array(lines.prefix(6)) == [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int((plan.segments.map(\.durationSeconds).max() ?? 1).rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ])
        #expect(lines.last == "#EXT-X-ENDLIST")

        // One EXTINF + URI pair per segment, URIs in order.
        let extinfs = lines.filter { $0.hasPrefix("#EXTINF:") }
        #expect(extinfs.count == plan.segments.count)
        let uris = lines.filter { !$0.hasPrefix("#") }
        #expect(uris == (0 ..< plan.segments.count).map(HLSSegmentPlan.segmentPath))

        // The point of the whole delivery: no master, no variant to rule
        // ineligible.
        #expect(!lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") })
    }

    @Test("Segment paths round-trip through the parser")
    func segmentPathRoundTrip() {
        #expect(HLSSegmentPlan.segmentIndex(fromPath: HLSSegmentPlan.segmentPath(0)) == 0)
        #expect(HLSSegmentPlan.segmentIndex(fromPath: HLSSegmentPlan.segmentPath(5851)) == 5851)
        #expect(HLSSegmentPlan.segmentIndex(fromPath: "init.mp4") == nil)
        #expect(HLSSegmentPlan.segmentIndex(fromPath: "seg.m4s") == nil)
        #expect(HLSSegmentPlan.segmentIndex(fromPath: "segX.m4s") == nil)
    }
}

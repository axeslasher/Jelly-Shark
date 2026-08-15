import Foundation
@testable import JellyfinKit
import Testing

@Suite("HLSSegmentPlan")
struct HLSSegmentPlanTests {
    /// Load the real ffmpeg fixture's index and the remuxer's timescale, so
    /// each test can build a plan at whatever merge target it needs. The
    /// fixture carries video keyframes/Cues at ~0, 2, 4, 6s over 8s.
    private func loadIndex() async throws -> (MatroskaIndex, Int) {
        let url = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: url)))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)
        return (index, remuxer.timescale)
    }

    /// The #99 guardrail. Cutting one segment per Cue is exactly what shipped
    /// the periodic frameskip; this asserts the merge is target-driven, lands
    /// every boundary on a Cue (a keyframe, so seeking stays exact), tiles the
    /// source with no gap or overlap, and leaves no interior segment far below
    /// the target.
    @Test("Segments merge adjacent cue spans up to the target, on keyframe boundaries")
    func segmentsTileCueSpans() async throws {
        let (index, timescale) = try await loadIndex()
        try #require(index.cues.count >= 2) // otherwise there is nothing to merge

        // A target below the finest Cue spacing degenerates to the old 1:1
        // mapping — proof the merge responds to the target rather than
        // collapsing unconditionally.
        let unmerged = HLSSegmentPlan(index: index, timescale: timescale, targetSegmentSeconds: 0)
        #expect(unmerged.segments.count == index.cues.count)

        // A target coarser than the ~2s Cue spacing produces materially
        // fewer, more uniform segments. The shipped 1:1 mapping fails this.
        let target = 6.0
        let plan = HLSSegmentPlan(index: index, timescale: timescale, targetSegmentSeconds: target)
        #expect(plan.segments.count < index.cues.count)

        let cueOffsets = Set(index.cues.map(\.clusterOffset))
        let cueTicks = Set(index.cues.map(\.timeTicks))

        // Every boundary lands on a Cue keyframe.
        for segment in plan.segments {
            #expect(cueOffsets.contains(segment.clusterOffset))
            #expect(cueTicks.contains(segment.timeTicks))
        }

        // Contiguous tiling: first starts at the first Cue, each end meets the
        // next start, the last closes at the segment's data end.
        #expect(plan.segments.first?.clusterOffset == index.cues[0].clusterOffset)
        for (a, b) in zip(plan.segments, plan.segments.dropFirst()) {
            #expect(a.clusterEndBound == b.clusterOffset)
        }
        #expect(plan.segments.last?.clusterEndBound == index.segmentDataEnd)

        // The time chain mirrors the offset chain: each segment's
        // nextTimeTicks is the next segment's start time. It becomes the last
        // video sample's duration at every boundary — the exact frameskip
        // class #99 fixed — so it must be pinned, not just membership-checked.
        for (a, b) in zip(plan.segments, plan.segments.dropFirst()) {
            #expect(a.nextTimeTicks == Int64(b.timeTicks))
        }
        #expect(plan.segments.last?.nextTimeTicks == nil)

        // No interior segment sits below the merge target: the sub-second
        // fragments #99 reported are gone (only the final EXTINF may be short).
        for segment in plan.segments.dropLast() {
            #expect(segment.durationSeconds >= target)
        }
    }

    @Test("The byte cap closes runs a malformed file's cue times never would")
    func byteCapBoundsMergeRuns() {
        // CueTimes that never advance (all defaulted to 0 — malformed but
        // parseable) satisfy the duration condition forever; only the byte
        // cap keeps the plan from collapsing the whole source into one
        // unboundedly large segment.
        let spacing: UInt64 = 8 * 1024 * 1024
        let cues = (0 ..< 20).map {
            MatroskaCuePoint(timeTicks: 0, clusterOffset: UInt64($0) * spacing)
        }
        let index = MatroskaIndex(
            timestampScaleNs: 1_000_000,
            durationTicks: nil,
            tracks: [],
            cues: cues,
            segmentDataStart: 0,
            segmentDataEnd: 20 * spacing,
        )
        let plan = HLSSegmentPlan(index: index, timescale: 1000)
        #expect(plan.segments.count > 1)
        for segment in plan.segments {
            // A run may overshoot the cap by at most one cue-to-cue span.
            let span = segment.clusterEndBound - segment.clusterOffset
            #expect(span <= HLSSegmentPlan.defaultMaxMergedSpanBytes + spacing)
        }
    }

    @Test("A corrupt out-of-range cue time mis-sizes a duration, never traps")
    func corruptCueTimeDoesNotTrap() {
        // 8 bytes of 0xFF in a CueTime parses as UInt64.max; the plan must
        // absorb it as a wrong EXTINF hint, not trap converting it to Int64.
        let cues = [
            MatroskaCuePoint(timeTicks: 0, clusterOffset: 0),
            MatroskaCuePoint(timeTicks: .max, clusterOffset: 1024),
            MatroskaCuePoint(timeTicks: 4000, clusterOffset: 2048),
        ]
        let index = MatroskaIndex(
            timestampScaleNs: 1_000_000,
            durationTicks: 8000,
            tracks: [],
            cues: cues,
            segmentDataStart: 0,
            segmentDataEnd: 4096,
        )
        let plan = HLSSegmentPlan(index: index, timescale: 1000)
        #expect(!plan.segments.isEmpty)
        for segment in plan.segments {
            #expect(segment.durationSeconds >= 0)
            #expect(segment.durationSeconds.isFinite)
        }
    }

    @Test("The undeclared-duration tail estimates a cue span, not the previous merged run")
    func tailFallbackEstimatesCueSpan() {
        // Cues every 2s with no declared Duration: the tail is one 2s cue
        // span, and its EXTINF hint must not inherit the previous segment's
        // ~6s merged duration.
        let cues = (0 ..< 4).map {
            MatroskaCuePoint(timeTicks: UInt64($0) * 2000, clusterOffset: UInt64($0) * 1024)
        }
        let index = MatroskaIndex(
            timestampScaleNs: 1_000_000,
            durationTicks: nil,
            tracks: [],
            cues: cues,
            segmentDataStart: 0,
            segmentDataEnd: 4096,
        )
        let plan = HLSSegmentPlan(index: index, timescale: 1000)
        #expect(plan.segments.count == 2)
        #expect(plan.segments[0].durationSeconds == 6)
        #expect(plan.segments[1].durationSeconds == 2)
    }

    @Test("Durations sum to the source duration across merged segments")
    func durations() async throws {
        let (index, timescale) = try await loadIndex()
        let plan = HLSSegmentPlan(index: index, timescale: timescale)
        for segment in plan.segments {
            #expect(segment.durationSeconds > 0)
        }
        let total = plan.segments.map(\.durationSeconds).reduce(0, +)
        let declared = try #require(index.durationSeconds)
        #expect(abs(total - declared) < 0.01)
    }

    @Test("The media playlist is a master-less ffmpeg-shaped VOD playlist")
    func mediaPlaylist() async throws {
        let (index, timescale) = try await loadIndex()
        let plan = HLSSegmentPlan(index: index, timescale: timescale)
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

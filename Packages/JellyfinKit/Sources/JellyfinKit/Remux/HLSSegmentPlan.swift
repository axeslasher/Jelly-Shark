import Foundation

/// The segment plan for a locally-remuxed HLS session (#172): one media
/// playlist over the Matroska index, computable from the index alone — before
/// any cluster is read.
///
/// Segments are **merged runs of adjacent Cues** targeting a fixed duration
/// (#99). A source's Cues land on its scene-cut keyframes, which are wildly
/// irregular — cutting one HLS segment per Cue produced fragments spanning
/// ~8,000× in size (876 B to 7 MB) and a periodic frameskip on device. Every
/// Cue is a keyframe, so every merged boundary still lands on one and seeking
/// stays exact; grouping them into ~target-second spans just gives AVPlayer
/// the uniform fragment cadence a fresh re-encode would.
///
/// Why a media playlist and no master: both halves were measured on the
/// Apple TV rig, 2026-08-02. AVFoundation's progressive file reader ignores
/// `sidx` outright and linear-scans the whole file before readiness (two
/// device rounds, structurally different moovs, identical scan signature),
/// so a progressive fMP4 is a dead end. Its HLS stack, meanwhile, refuses
/// any master declaring 4K attributes (`AVFoundationErrorDomain -11868`,
/// underlying `CoreMediaErrorDomain -17223` on tvOS 26.6) — but a media
/// playlist with no master never reaches variant selection: nothing is
/// declared, so nothing can be ruled ineligible, and genuine 4K PQ segments
/// reached `readyToPlay` and buffered on the SDR-panel device.
///
/// The #226 spike (2026-08-17) measured the converse: of the ranges tested
/// (SDR, HLG, PQ), variant eligibility on an SDR display refused only PQ.
/// Declared PQ/4K
/// attributes fail instantly; every other master shape (minimal, complete,
/// VIDEO-RANGE omitted, even falsely declared SDR) fails `-12927` after
/// the init segment is fetched — the content check is authoritative and
/// cannot be evaded by declaration. The identical served shape PLAYS under
/// a master when the content is SDR or HLG (HLG is SDR-backward-compatible
/// by design), so the refusals were never about this playlist's authoring.
/// Master-less is therefore the only shape for PQ/DV-on-SDR sessions — the
/// dominant remux population — while HLG sessions could take masters. See
/// docs/PLAYBACK_MATRIX.md § HDR variant selection for the full run table.
///
/// The playlist mirrors ffmpeg's `-f hls -hls_segment_type fmp4` VOD output
/// line for line — that exact shape is what the device round verified.
public struct HLSSegmentPlan: Sendable {
    /// One media segment: a cue-to-cue source span and its playlist duration.
    public struct Segment: Sendable, Equatable {
        /// Source range: [clusterOffset, endBound) for the demuxer.
        public let clusterOffset: UInt64
        public let clusterEndBound: UInt64
        /// Cue time of this span and of the next (for last-sample duration).
        public let timeTicks: UInt64
        public let nextTimeTicks: Int64?
        /// The `#EXTINF` duration in seconds.
        public let durationSeconds: Double
    }

    public let segments: [Segment]

    /// Target segment duration in seconds. Merging closes a segment at the
    /// first Cue at or past this mark (ffmpeg's `-hls_time` semantics), so
    /// every segment but the last is at least this long. The `-hls_time 6`
    /// ffmpeg workbench probe from #99 played smooth on device, so 6 is the
    /// starting guess — bisect it on device within the ~2–6s band per
    /// `CLAUDE.md` rather than trusting a bench number.
    public static let defaultTargetSegmentSeconds: Double = 6

    /// Byte ceiling on a merged run: merging stops extending once the run
    /// already spans this much of the source, whatever its duration (a run
    /// may overshoot by at most one cue-to-cue span). Segment production
    /// holds several concurrent copies of a span — demuxed frames, per-track
    /// fragment data, the muxed segment — so span *bytes*, not seconds, are
    /// what the memory budget bounds. This is also the backstop for a
    /// malformed file whose CueTimes never advance: without it, such a file
    /// merges into one whole-source segment. A single cue-to-cue span larger
    /// than this still becomes one segment; the source sets that floor.
    public static let defaultMaxMergedSpanBytes: UInt64 = 32 * 1024 * 1024

    /// The relative URIs the playlist references; the server's routes must
    /// answer exactly these.
    public static let playlistPath = "media.m3u8"
    public static let initSegmentPath = "init.mp4"
    public static func segmentPath(_ index: Int) -> String {
        "seg\(index).m4s"
    }

    /// Inverse of `segmentPath`: "seg12.m4s" → 12, anything else → nil.
    public static func segmentIndex(fromPath path: String) -> Int? {
        guard path.hasPrefix("seg"), path.hasSuffix(".m4s") else { return nil }
        return Int(path.dropFirst(3).dropLast(4))
    }

    /// Build the plan from a loaded index. `timescale` is ticks per second
    /// and must match what the init segment declares. `targetSegmentSeconds`
    /// is the merge target (see `defaultTargetSegmentSeconds`); a value below
    /// the finest Cue spacing degenerates to one segment per Cue.
    /// `maxMergedSpanBytes` caps how much source a run may cover (see
    /// `defaultMaxMergedSpanBytes`).
    public init(
        index: MatroskaIndex,
        timescale: Int,
        targetSegmentSeconds: Double = HLSSegmentPlan.defaultTargetSegmentSeconds,
        maxMergedSpanBytes: UInt64 = HLSSegmentPlan.defaultMaxMergedSpanBytes,
    ) {
        let cues = index.cues
        let ticksPerSecond = Double(max(timescale, 1))
        let targetTicks = max(targetSegmentSeconds, 0) * ticksPerSecond
        var segments: [Segment] = []

        var groupStart = 0
        // Rolling per-cue spacing estimate, for the undeclared-duration tail.
        var cueSpacingSeconds: Double = 1
        while groupStart < cues.count {
            let start = cues[groupStart]
            // Extend the run to the first Cue at or past the target from the
            // group's start, closing early once the run spans the byte cap.
            // Every Cue is a keyframe, so wherever the run closes it closes
            // on a seekable boundary. Time deltas in Double rather than
            // UInt64 subtraction: Cues are sorted by offset, and a malformed
            // file's non-monotonic times must not trap here — the byte cap
            // is what keeps such a file's runs bounded.
            var groupEnd = groupStart
            while groupEnd + 1 < cues.count,
                  Double(cues[groupEnd + 1].timeTicks) - Double(start.timeTicks) < targetTicks,
                  cues[groupEnd + 1].clusterOffset - start.clusterOffset < maxMergedSpanBytes
            {
                groupEnd += 1
            }
            let hasNext = groupEnd + 1 < cues.count
            let endBound = hasNext ? cues[groupEnd + 1].clusterOffset : index.segmentDataEnd
            // Clamping, not a trapping conversion: a corrupt CueTime (8 bytes
            // of 0xFF parses as UInt64.max) may mis-size a duration but must
            // never crash the plan.
            let nextTicks: Int64? = hasNext ? Int64(clamping: cues[groupEnd + 1].timeTicks) : nil
            let cueCount = groupEnd - groupStart + 1
            let duration: Double = if hasNext {
                max(0, Double(cues[groupEnd + 1].timeTicks) - Double(start.timeTicks)) / ticksPerSecond
            } else if let total = index.durationTicks, total > Double(start.timeTicks) {
                // The final span's duration comes from the declared total.
                (total - Double(start.timeTicks)) / ticksPerSecond
            } else {
                // No declared duration: estimate from the cue spacing seen so
                // far, scaled to this run's cue count. Repeating the previous
                // segment's *merged* duration would overshoot a short tail by
                // up to the whole merge target. Either way it only mis-sizes
                // the final EXTINF — a hint, not timing.
                cueSpacingSeconds * Double(cueCount)
            }
            if hasNext, duration > 0 {
                cueSpacingSeconds = duration / Double(cueCount)
            }
            segments.append(Segment(
                clusterOffset: start.clusterOffset,
                clusterEndBound: endBound,
                timeTicks: start.timeTicks,
                nextTimeTicks: nextTicks,
                durationSeconds: duration,
            ))
            groupStart = groupEnd + 1
        }
        self.segments = segments
    }

    /// The VOD media playlist, ffmpeg's fMP4 shape: version 7, an
    /// `EXT-X-MAP` for the init segment, one `EXTINF` per span, `ENDLIST`.
    public func mediaPlaylist() -> String {
        // Every EXTINF rounded to the nearest integer must be <= the target.
        let target = Int((segments.map(\.durationSeconds).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(Self.initSegmentPath)\"",
        ]
        for (i, segment) in segments.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.6f", segment.durationSeconds)),")
            lines.append(Self.segmentPath(i))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

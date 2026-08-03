import Foundation

/// The segment plan for a locally-remuxed HLS session (#172): one media
/// playlist over cue-to-cue spans, computable from the Matroska index alone
/// — before any cluster is read.
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
    /// and must match what the init segment declares.
    public init(index: MatroskaIndex, timescale: Int) {
        let cues = index.cues
        let ticksPerSecond = Double(max(timescale, 1))
        var segments: [Segment] = []
        segments.reserveCapacity(cues.count)
        for (i, cue) in cues.enumerated() {
            let endBound = i + 1 < cues.count ? cues[i + 1].clusterOffset : index.segmentDataEnd
            let nextTicks = i + 1 < cues.count ? Int64(cues[i + 1].timeTicks) : nil
            let duration: Double = if let nextTicks {
                Double(nextTicks - Int64(cue.timeTicks)) / ticksPerSecond
            } else if let total = index.durationTicks, total > Double(cue.timeTicks) {
                // The final span's duration comes from the declared total.
                (total - Double(cue.timeTicks)) / ticksPerSecond
            } else {
                // No declared duration: repeat the previous span's, which
                // only mis-sizes the final EXTINF — a hint, not timing.
                segments.last?.durationSeconds ?? 1
            }
            segments.append(Segment(
                clusterOffset: cue.clusterOffset,
                clusterEndBound: endBound,
                timeTicks: cue.timeTicks,
                nextTimeTicks: nextTicks,
                durationSeconds: duration,
            ))
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

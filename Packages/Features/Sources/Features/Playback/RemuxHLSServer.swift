import Foundation
import JellyfinKit
import Network
import OSLog

/// A loopback HTTP server presenting an in-app Matroska remux as a
/// master-less HLS media playlist (#172).
///
/// This exists because AVFoundation's HDR eligibility gate (#146) fires at
/// HLS variant selection over DECLARED master attributes: a master
/// declaring 4K PQ is refused on an SDR display (`-11868`, underlying
/// CoreMedia `-17223`) before a single segment is fetched — but a media
/// playlist with no master never reaches variant selection, and genuine
/// 4K PQ segments reached `readyToPlay` and buffered on the same device
/// (measured 2026-08-02). The progressive alternative is equally settled:
/// AVFoundation's file reader ignores `sidx` and linear-scans the whole
/// file, so the manifest-driven stack is the only reader that can be told
/// where the fragments are — and the playlist is how it is told.
///
/// Routes are exactly the URIs `HLSSegmentPlan.mediaPlaylist()` references:
/// `/media.m3u8`, `/init.mp4`, `/seg<n>.m4s`. Segments are remuxed on
/// demand from ranged reads of the original MKV.
final class RemuxHLSServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let demuxer: MatroskaDemuxer
    private let remuxer: MatroskaFMP4Remuxer
    private let plan: HLSSegmentPlan
    private let initSegment: Data
    private let playlist: Data

    private let http = LoopbackHTTPListener(
        queueLabel: "com.justinlascelle.jellyshark.remux-hls-server",
        logPrefix: "[remux-hls]",
    )
    private var queue: DispatchQueue {
        http.queue
    }

    /// Called at most once, off the main actor, when segment production
    /// fails with a deterministic error — the file's structure, not the
    /// network — so no amount of AVPlayer retrying can heal it and the
    /// delivery should rebuild on its next rung (#176's failure posture).
    var onUnrecoverableSegmentFailure: (@Sendable () -> Void)?
    /// One-shot guard for the callback; accessed on `queue`.
    private var unrecoverableFailureReported = false

    /// Startup diagnosis instrumentation: the request pattern is the one
    /// signal that distinguishes a healthy session (playlist + init + a
    /// steady forward march of segments) from a pathological one. Numbered
    /// requests with elapsed time make that legible in one glance at the
    /// console.
    private let startedAt = ContinuousClock.now
    private var requestCount = 0

    /// Segments already produced, newest last. Playback fetches forward,
    /// so a shallow cache absorbs stall-retry re-requests; bounded because
    /// the plan caps how many source bytes a merged span may cover
    /// (`HLSSegmentPlan.defaultMaxMergedSpanBytes`).
    private var segmentCache: [(index: Int, data: Data)] = []
    private static let segmentCacheLimit = 2

    /// Productions in flight, so overlapping requests share one remux — a
    /// span remux is expensive enough that racing it doubles serve latency
    /// (measured on the 2026-08-02 progressive device round).
    private var segmentTasks: [Int: Task<Data, Error>] = [:]

    /// ffmpeg prepends this `styp` to every fMP4 media segment. Mirror the
    /// device-verified shape byte for byte — this branch has twice paid a
    /// device round for deviating from what ffmpeg emits.
    private static let styp = Data([
        0x00, 0x00, 0x00, 0x18, 0x73, 0x74, 0x79, 0x70, // size 24, 'styp'
        0x6D, 0x73, 0x64, 0x68, // major brand 'msdh'
        0x00, 0x00, 0x00, 0x00, // minor version
        0x6D, 0x73, 0x64, 0x68, 0x6D, 0x73, 0x69, 0x78, // compatible 'msdh' 'msix'
    ])

    init(demuxer: MatroskaDemuxer, remuxer: MatroskaFMP4Remuxer, plan: HLSSegmentPlan, initSegment: Data) {
        self.demuxer = demuxer
        self.remuxer = remuxer
        self.plan = plan
        self.initSegment = initSegment
        playlist = Data(plan.mediaPlaylist().utf8)
        http.route = { [weak self] target, connection in
            self?.route(target, on: connection)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start listening on an ephemeral loopback port.
    /// - Returns: The media playlist URL, or nil if the listener could not
    ///   start or the calling task was cancelled.
    func start() async -> URL? {
        guard let port = await http.start() else { return nil }
        Self.logger.info("[remux-hls] listening on 127.0.0.1:\(port) (\(self.plan.segments.count) segments, init \(self.initSegment.count) bytes)")
        return URL(string: "http://127.0.0.1:\(port)/\(HLSSegmentPlan.playlistPath)")
    }

    func stop() {
        http.stop()
        // Cancel in-flight productions too: each rides ranged URLSession
        // reads, so an abandoned one would otherwise keep pulling span-sized
        // data from the origin after the session is gone.
        let tasks = queue.sync { () -> [Task<Data, Error>] in
            defer { segmentTasks.removeAll() }
            return Array(segmentTasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Routing (on the listener queue)

    private func route(_ target: String?, on connection: NWConnection) {
        guard let target else {
            http.send(status: "404 Not Found", on: connection)
            return
        }

        requestCount += 1
        let request = requestCount
        let elapsed = ContinuousClock.now - startedAt
        let path = String(target.dropFirst())
        Self.logger.info("[remux-hls] #\(request) +\(elapsed, privacy: .public) GET \(path, privacy: .public)")

        if path == HLSSegmentPlan.playlistPath {
            http.send(body: playlist, contentType: "application/vnd.apple.mpegurl", on: connection)
        } else if path == HLSSegmentPlan.initSegmentPath {
            http.send(body: initSegment, contentType: "video/mp4", on: connection)
        } else if let index = HLSSegmentPlan.segmentIndex(fromPath: path), plan.segments.indices.contains(index) {
            Task { await self.serveSegment(index, request: request, on: connection) }
        } else {
            Self.logger.warning("[remux-hls] 404 \(path, privacy: .public)")
            http.send(status: "404 Not Found", on: connection)
        }
    }

    // MARK: - Serving

    private func serveSegment(_ index: Int, request: Int, on connection: NWConnection) async {
        let data: Data
        do {
            data = try await segment(at: index)
        } catch {
            // Nothing has been sent yet, so the honest failure is a 500:
            // AVPlayer retries or stalls, and nothing corrupt is ever
            // served. What happens next depends on the error's class: a
            // demux/remux error is the file's structure and will fail
            // identically on every retry, so it demotes the delivery; a
            // network error can heal, so the retries are left to run.
            Self.logger.warning("[remux-hls] segment \(index) failed: \(error, privacy: .public)")
            if error is MatroskaError || error is MatroskaFMP4Remuxer.RemuxError {
                reportUnrecoverableFailure()
            }
            http.send(status: "500 Internal Server Error", on: connection)
            return
        }
        Self.logger.info("[remux-hls] #\(request) 200 seg\(index) \(data.count) bytes")
        http.send(body: data, contentType: "video/iso.segment", on: connection)
    }

    private func reportUnrecoverableFailure() {
        let firstReport = queue.sync { () -> Bool in
            defer { unrecoverableFailureReported = true }
            return !unrecoverableFailureReported
        }
        if firstReport {
            onUnrecoverableSegmentFailure?()
        }
    }

    private func segment(at index: Int) async throws -> Data {
        if let cached = queue.sync(execute: { segmentCache.first { $0.index == index }?.data }) {
            return cached
        }
        let (task, isProducer) = queue.sync { () -> (Task<Data, Error>, Bool) in
            if let inFlight = segmentTasks[index] {
                return (inFlight, false)
            }
            let task = Task { [demuxer, remuxer, plan] in
                let segment = plan.segments[index]
                let started = ContinuousClock.now
                let span = try await demuxer.readClusters(from: segment.clusterOffset, to: segment.clusterEndBound)
                // The next span's opening cluster carries any straddling
                // GOP's tail frames; the remuxer re-partitions at keyframes
                // so fragment timelines tile (#99).
                let nextSegment = index + 1 < plan.segments.count ? plan.segments[index + 1] : nil
                let nextSpanHead = try await nextSegment.map {
                    try await demuxer.readFirstCluster(at: $0.clusterOffset, endBound: $0.clusterEndBound)
                }
                let fragment = try remuxer.makeFragment(sequence: index + 1, cluster: span, nextSpanHead: nextSpanHead)
                Self.logger.info("[remux-hls] segment \(index) produced: \(fragment.count) bytes in \(ContinuousClock.now - started, privacy: .public)")
                return Self.styp + fragment
            }
            segmentTasks[index] = task
            return (task, true)
        }
        defer {
            if isProducer {
                queue.sync { segmentTasks[index] = nil }
            }
        }
        let produced = try await task.value
        if isProducer {
            queue.sync {
                segmentCache.append((index, produced))
                if segmentCache.count > Self.segmentCacheLimit {
                    segmentCache.removeFirst()
                }
            }
        }
        return produced
    }
}

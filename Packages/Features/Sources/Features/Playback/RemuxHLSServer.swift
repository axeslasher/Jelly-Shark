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

    private let queue = DispatchQueue(label: "com.justinlascelle.jellyshark.remux-hls-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Startup diagnosis instrumentation: the request pattern is the one
    /// signal that distinguishes a healthy session (playlist + init + a
    /// steady forward march of segments) from a pathological one. Numbered
    /// requests with elapsed time make that legible in one glance at the
    /// console.
    private let startedAt = ContinuousClock.now
    private var requestCount = 0

    /// Segments already produced, newest last. Playback fetches forward,
    /// so a shallow cache absorbs stall-retry re-requests; bounded because
    /// entries are span-sized.
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
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle (same listener pattern as PlaybackLocalServer)

    /// Start listening on an ephemeral loopback port.
    /// - Returns: The media playlist URL, or nil if the listener could not
    ///   start or the calling task was cancelled.
    func start() async -> URL? {
        guard !Task.isCancelled else { return nil }

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters)
        } catch {
            Self.logger.warning("[remux-hls] failed to create listener: \(error, privacy: .public)")
            return nil
        }

        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let port: UInt16? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue)
                    case .failed, .cancelled:
                        resumed = true
                        continuation.resume(returning: nil)
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        } onCancel: {
            listener.cancel()
        }

        guard let port else {
            if !Task.isCancelled {
                Self.logger.warning("[remux-hls] listener failed to become ready")
            }
            stop()
            return nil
        }

        Self.logger.info("[remux-hls] listening on 127.0.0.1:\(port) (\(self.plan.segments.count) segments, init \(self.initSegment.count) bytes)")
        return URL(string: "http://127.0.0.1:\(port)/\(HLSSegmentPlan.playlistPath)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [connections] in
            for connection in connections.values {
                connection.cancel()
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                connection.cancel()
            } else if case .cancelled = state {
                self.connections[ObjectIdentifier(connection)] = nil
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let head = String(decoding: data, as: UTF8.self)
            let lines = head.split(separator: "\r\n")
            guard let requestLine = lines.first,
                  requestLine.hasPrefix("GET "),
                  let target = requestLine.split(separator: " ").dropFirst().first
            else {
                Self.logger.warning("[remux-hls] refused request: \(lines.first.map(String.init) ?? "<empty>", privacy: .public)")
                self.send(status: "404 Not Found", on: connection)
                return
            }

            self.requestCount += 1
            let request = self.requestCount
            let elapsed = ContinuousClock.now - self.startedAt
            let path = String(target.dropFirst())
            Self.logger.info("[remux-hls] #\(request) +\(elapsed, privacy: .public) GET \(path, privacy: .public)")

            if path == HLSSegmentPlan.playlistPath {
                self.send(self.playlist, contentType: "application/vnd.apple.mpegurl", on: connection)
            } else if path == HLSSegmentPlan.initSegmentPath {
                self.send(self.initSegment, contentType: "video/mp4", on: connection)
            } else if let index = HLSSegmentPlan.segmentIndex(fromPath: path), self.plan.segments.indices.contains(index) {
                Task { await self.serveSegment(index, request: request, on: connection) }
            } else {
                Self.logger.warning("[remux-hls] 404 \(path, privacy: .public)")
                self.send(status: "404 Not Found", on: connection)
            }
        }
    }

    // MARK: - Serving

    private func serveSegment(_ index: Int, request: Int, on connection: NWConnection) async {
        let data: Data
        do {
            data = try await segment(at: index)
        } catch {
            // Nothing has been sent yet, so the honest failure is a 500:
            // AVPlayer retries or stalls into the delivery watchdog, and
            // nothing corrupt is ever served.
            Self.logger.warning("[remux-hls] segment \(index) failed: \(error, privacy: .public)")
            send(status: "500 Internal Server Error", on: connection)
            return
        }
        Self.logger.info("[remux-hls] #\(request) 200 seg\(index) \(data.count) bytes")
        send(data, contentType: "video/iso.segment", on: connection)
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
                let fragment = try remuxer.makeFragment(
                    sequence: index + 1,
                    cluster: span,
                    nextClusterTimeTicks: segment.nextTimeTicks,
                )
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

    // MARK: - HTTP plumbing

    private func send(_ body: Data, contentType: String, on connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(status: String, on connection: NWConnection) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

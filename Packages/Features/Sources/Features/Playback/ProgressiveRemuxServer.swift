import Foundation
import JellyfinKit
import Network
import OSLog

/// A loopback HTTP server presenting an in-app Matroska remux as one
/// progressive fMP4 file (#172).
///
/// This exists because AVFoundation's HDR eligibility gate (`-12927`, #146)
/// is a property of HLS variant selection: an app-built HLS master is
/// refused on SDR displays exactly as the server's is, while a progressive
/// asset — no manifest, nothing to rule ineligible — direct-plays and
/// tone-maps on-device (premise confirmed on the Apple TV rig, see #172).
///
/// The served file is `ProgressiveMP4Layout`'s virtual byte map:
/// `[init][sidx][slot 0][slot 1]…`, where each slot is one cue-to-cue span
/// remuxed on demand from ranged reads of the original MKV and padded to
/// its fixed budget. `Range` requests are answered 206 against that map, so
/// AVPlayer scrubs natively via the sidx; the padding bytes only ever cross
/// loopback.
final class ProgressiveRemuxServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let demuxer: MatroskaDemuxer
    private let remuxer: MatroskaFMP4Remuxer
    private let layout: ProgressiveMP4Layout

    private let queue = DispatchQueue(label: "com.justinlascelle.jellyshark.progressive-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Padded fragments already produced, newest last. Playback walks
    /// forward with overlapping ranges, so a shallow cache absorbs nearly
    /// every re-request; bounded because entries are span-sized.
    private var fragmentCache: [(index: Int, data: Data)] = []
    private static let fragmentCacheLimit = 2

    init(demuxer: MatroskaDemuxer, remuxer: MatroskaFMP4Remuxer, layout: ProgressiveMP4Layout) {
        self.demuxer = demuxer
        self.remuxer = remuxer
        self.layout = layout
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle (same listener pattern as PlaybackLocalServer)

    /// Start listening on an ephemeral loopback port.
    /// - Returns: The progressive stream URL, or nil if the listener could
    ///   not start or the calling task was cancelled.
    func start() async -> URL? {
        guard !Task.isCancelled else { return nil }

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters)
        } catch {
            Self.logger.warning("[progressive] failed to create listener: \(error, privacy: .public)")
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
                Self.logger.warning("[progressive] listener failed to become ready")
            }
            stop()
            return nil
        }

        Self.logger.info("[progressive] listening on 127.0.0.1:\(port) (\(self.layout.slots.count) fragments, \(self.layout.totalSize) bytes)")
        return URL(string: "http://127.0.0.1:\(port)/stream.mp4")
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
                  let path = requestLine.split(separator: " ").dropFirst().first,
                  path == "/stream.mp4"
            else {
                self.send(status: "404 Not Found", on: connection)
                return
            }

            let rangeHeader = lines
                .first { $0.lowercased().hasPrefix("range:") }
                .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

            Task { await self.serve(rangeHeader: rangeHeader, on: connection) }
        }
    }

    // MARK: - Serving

    private func serve(rangeHeader: String?, on connection: NWConnection) async {
        let total = layout.totalSize
        let range: Range<UInt64>
        var status = "200 OK"
        var headers = ["Accept-Ranges": "bytes", "Content-Type": "video/mp4"]

        if let rangeHeader {
            guard let requested = Self.parseByteRange(rangeHeader, totalSize: total) else {
                headers["Content-Range"] = "bytes */\(total)"
                send(status: "416 Range Not Satisfiable", headers: headers, on: connection)
                return
            }
            range = requested
            status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
        } else {
            range = 0 ..< total
        }

        let regions = layout.regions(for: range)
        sendHead(status: status, headers: headers, contentLength: Int(range.upperBound - range.lowerBound), on: connection)
        await streamRegions(regions, on: connection)
    }

    /// `bytes=a-b`, `bytes=a-`, or `bytes=-suffix` → a half-open range.
    static func parseByteRange(_ header: String, totalSize: UInt64) -> Range<UInt64>? {
        let value = header.lowercased().hasPrefix("bytes=") ? String(header.dropFirst(6)) : header
        // Multi-range requests are legal HTTP but AVPlayer never sends them.
        guard !value.contains(",") else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            return max(totalSize, suffix) - suffix ..< totalSize
        }
        guard let start = UInt64(parts[0]), start < totalSize else { return nil }
        if parts[1].isEmpty {
            return start ..< totalSize
        }
        guard let end = UInt64(parts[1]), end >= start else { return nil }
        return start ..< min(end + 1, totalSize)
    }

    private func streamRegions(_ regions: [ProgressiveMP4Layout.Region], on connection: NWConnection) async {
        for region in regions {
            let chunk: Data
            switch region {
            case let .head(subrange):
                let head = layout.head
                chunk = head.subdata(in: head.startIndex + subrange.lowerBound ..< head.startIndex + subrange.upperBound)
            case let .fragment(index, subrange):
                do {
                    let fragment = try await paddedFragment(at: index)
                    chunk = fragment.subdata(in: fragment.startIndex + subrange.lowerBound ..< fragment.startIndex + subrange.upperBound)
                } catch {
                    // The head already went out, so the honest failure is a
                    // dropped connection: AVPlayer retries or stalls into the
                    // delivery watchdog, and nothing corrupt is ever served.
                    Self.logger.warning("[progressive] fragment \(index) failed: \(error, privacy: .public)")
                    connection.cancel()
                    return
                }
            }
            let sent = await sendChunk(chunk, on: connection)
            guard sent else { return } // peer went away (a scrub abort)
        }
        connection.cancel()
    }

    private func paddedFragment(at index: Int) async throws -> Data {
        if let cached = queue.sync(execute: { fragmentCache.first { $0.index == index }?.data }) {
            return cached
        }
        let slot = layout.slots[index]
        let span = try await demuxer.readClusters(from: slot.clusterOffset, to: slot.clusterEndBound)
        let fragment = try remuxer.makeFragment(
            sequence: index + 1,
            cluster: span,
            nextClusterTimeTicks: slot.nextTimeTicks,
        )
        let padded = try layout.padded(fragment: fragment, slot: index)
        queue.sync {
            fragmentCache.append((index, padded))
            if fragmentCache.count > Self.fragmentCacheLimit {
                fragmentCache.removeFirst()
            }
        }
        return padded
    }

    // MARK: - HTTP plumbing

    private func sendHead(status: String, headers: [String: String], contentLength: Int, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Length: \(contentLength)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    /// Send one region's bytes, awaiting delivery so a long response never
    /// buffers the whole file into the connection.
    private func sendChunk(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func send(status: String, headers: [String: String] = [:], on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Length: 0\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

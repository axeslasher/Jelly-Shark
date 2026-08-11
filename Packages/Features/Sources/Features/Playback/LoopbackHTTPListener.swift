import Foundation
import Network
import OSLog

/// The listener/connection plumbing shared by the playback loopback servers
/// (`PlaybackLocalServer`, `RemuxHLSServer`): bind an ephemeral loopback
/// port, own the connection table, parse the GET request line, and hand the
/// target to the server's route handler. Extracted because the two servers
/// had drifted into ~90 structurally identical lines — and both copies read
/// the connection table off its queue in `stop()`.
final class LoopbackHTTPListener: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    /// Every touch of the connection table happens here; `NWConnection`
    /// callbacks and the route handler run here too. Owning servers put
    /// their own queue-confined state on it rather than keeping a second
    /// queue.
    let queue: DispatchQueue

    private let logPrefix: String
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Called on `queue` with the request-line target (leading "/"
    /// included), or nil when the head is not a GET request — the server
    /// decides whether that draws a 404 or a dropped connection. Set once,
    /// before `start()`.
    var route: (@Sendable (String?, NWConnection) -> Void)?

    init(queueLabel: String, logPrefix: String) {
        queue = DispatchQueue(label: queueLabel)
        self.logPrefix = logPrefix
    }

    /// Start listening on an ephemeral loopback port.
    /// - Returns: The bound port, or nil if the listener could not start
    ///   (callers fall back) or the calling task was cancelled (callers
    ///   must unwind, not fall back).
    func start() async -> UInt16? {
        // A cancelled build must not bind a port it will never serve from
        guard !Task.isCancelled else { return nil }

        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters)
        } catch {
            Self.logger.warning("\(self.logPrefix, privacy: .public) failed to create listener: \(error, privacy: .public)")
            return nil
        }

        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        // The readiness wait honors task cancellation, and must: a stream
        // build superseded by a newer one (#212) is cancelled-and-awaited,
        // and an uncancellable park here would chain-block every later build
        // behind an unbounded network-listener wait. Cancelling the listener
        // drives its state to `.cancelled`, which resumes through the same
        // handler as a natural failure — no second resume path.
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
            // A cancelled build's nil is not a failure — don't log it as one
            if !Task.isCancelled {
                Self.logger.warning("\(self.logPrefix, privacy: .public) listener failed to become ready")
            }
            stop()
            return nil
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // Copy-and-clear on the queue that owns the table, cancel outside
        // it: the previous shape captured the dictionary on the caller's
        // thread while the listener queue mutated it.
        let open = queue.sync { () -> [NWConnection] in
            defer { connections.removeAll() }
            return Array(connections.values)
        }
        for connection in open {
            connection.cancel()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        // Delivered on `queue` (the queue the connection starts on), where
        // the connections dictionary is always accessed
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                connection.cancel()
            } else if case .cancelled = state {
                self?.connections[ObjectIdentifier(connection)] = nil
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

            // GET requests fit comfortably in one read; only the request
            // line matters
            let head = String(decoding: data, as: UTF8.self)
            let requestLine = head.split(separator: "\r\n").first
            let target: String? = requestLine.flatMap { line in
                guard line.hasPrefix("GET "),
                      let target = line.split(separator: " ").dropFirst().first
                else { return nil }
                return String(target)
            }
            if target == nil {
                Self.logger.warning("\(self.logPrefix, privacy: .public) refused request: \(requestLine.map(String.init) ?? "<empty>", privacy: .public)")
            }
            self.route?(target, connection)
        }
    }

    // MARK: - HTTP plumbing

    func send(
        status: String = "200 OK",
        headers: [String: String] = [:],
        body: Data = Data(),
        contentType: String? = nil,
        on connection: NWConnection,
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

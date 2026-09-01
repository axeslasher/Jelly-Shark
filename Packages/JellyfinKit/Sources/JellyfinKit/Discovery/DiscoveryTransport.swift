import Foundation

/// The UDP half of discovery, behind a protocol so the wire format and the collection
/// window stay testable with no network — and, on the platforms that gate it, with no
/// local-network permission prompt in the test suite.
protocol DiscoveryTransport: Sendable {
    /// Broadcasts `payload` and yields every reply datagram until the consumer stops
    /// iterating, at which point the transport tears its socket down.
    ///
    /// Throws only when the probe could not be sent at all. A network where nothing
    /// answers is a successful probe with no replies, not a failure.
    func probe(payload: Data, port: UInt16) throws(DiscoveryFailure) -> AsyncStream<Data>
}

/// Why a probe never left the device. Carries an `errno` and nothing else: the reason
/// strings are fixed, so a failure can be logged in full without leaking anything.
enum DiscoveryFailure: Error, Sendable {
    /// The OS refused to give us a UDP socket.
    case socketUnavailable(errno: Int32)
    /// The socket exists but wouldn't take the options broadcasting needs.
    case optionRejected(errno: Int32)
    /// Nothing accepted the datagram — no route, or broadcast denied.
    case probeUnsent(errno: Int32)

    var reason: String {
        switch self {
        case .socketUnavailable: "socket unavailable"
        case .optionRejected: "broadcast option rejected"
        case .probeUnsent: "no broadcast address accepted the probe"
        }
    }

    var code: Int32 {
        switch self {
        case let .socketUnavailable(errno), let .optionRejected(errno), let .probeUnsent(errno): errno
        }
    }
}

/// The collection window, injectable so tests never sleep on a wall clock.
protocol DiscoveryWindow: Sendable {
    func wait(_ duration: Duration) async
}

/// The real window. Returns early rather than throwing when the calling task is
/// cancelled, so a cancelled discovery still reports whatever it collected.
struct TaskSleepWindow: DiscoveryWindow {
    func wait(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

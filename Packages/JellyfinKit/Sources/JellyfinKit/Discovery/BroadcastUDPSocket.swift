import Darwin
import Foundation

/// An unconnected IPv4 UDP socket that broadcasts the discovery probe and yields the
/// replies.
///
/// BSD sockets rather than Network framework, for two independent reasons. Apple's
/// TN3151 says plainly that Network framework "does not support UDP broadcast" and to
/// use BSD Sockets instead. And the reply doesn't come back from the address we send
/// to: the server answers from its own `<ip>:7359`, which the connected UDP flow an
/// `NWConnection` sets up would discard as coming from the wrong peer.
struct BroadcastUDPSocket: DiscoveryTransport {
    func probe(payload: Data, port: UInt16) throws(DiscoveryFailure) -> AsyncStream<Data> {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { throw DiscoveryFailure.socketUnavailable(errno: errno) }

        do {
            try Self.configure(handle)
            try Self.send(payload, from: handle, to: port)
        } catch {
            close(handle)
            throw error
        }

        return Self.replies(from: handle)
    }

    // MARK: - Socket setup

    private static func configure(_ handle: Int32) throws(DiscoveryFailure) {
        var enabled: Int32 = 1
        guard setsockopt(handle, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DiscoveryFailure.optionRejected(errno: errno)
        }

        // Non-blocking so the read source's handler can never stall a dispatch queue
        // on a socket that went quiet.
        let flags = fcntl(handle, F_GETFL, 0)
        guard flags >= 0, fcntl(handle, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DiscoveryFailure.optionRejected(errno: errno)
        }
    }

    // MARK: - Sending

    private static func send(_ payload: Data, from handle: Int32, to port: UInt16) throws(DiscoveryFailure) {
        var delivered = 0
        var lastErrno: Int32 = 0

        for destination in destinations() {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: destination)

            var sendErrno: Int32 = 0
            let sent = payload.withUnsafeBytes { buffer in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        let result = sendto(
                            handle,
                            buffer.baseAddress,
                            buffer.count,
                            0,
                            socketAddress,
                            socklen_t(MemoryLayout<sockaddr_in>.size),
                        )
                        // Read here, not after the closures unwind: errno only holds
                        // its value until the next library call, and unwinding two
                        // nested closures is not guaranteed to be free of those.
                        sendErrno = errno
                        return result
                    }
                }
            }

            if sent == payload.count {
                delivered += 1
            } else {
                lastErrno = sendErrno
            }
        }

        // One interface refusing the probe is normal; every one refusing it means the
        // round can't produce anything, so the caller may as well stop now.
        guard delivered > 0 else { throw DiscoveryFailure.probeUnsent(errno: lastErrno) }
    }

    /// 255.255.255.255, plus the directed broadcast address of every broadcast-capable
    /// IPv4 interface that's up.
    ///
    /// The limited broadcast only leaves by the default route, so an Apple TV with
    /// both Ethernet and Wi-Fi up would otherwise probe just one of the two networks.
    /// Sending to each subnet's own broadcast address covers the rest; a server that
    /// hears the probe twice answers twice, and the collector collapses that by id.
    private static func destinations() -> [in_addr_t] {
        var destinations: [in_addr_t] = [INADDR_BROADCAST]
        for address in interfaceBroadcastAddresses() where !destinations.contains(address) {
            destinations.append(address)
        }
        return destinations
    }

    private static func interfaceBroadcastAddresses() -> [in_addr_t] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [in_addr_t] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            // Compared in the field's own UInt32 width: narrowing it to Int32 would
            // trap on a flags word the app doesn't control.
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_BROADCAST) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }

            guard let addressPointer = interface.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET),
                  let netmaskPointer = interface.pointee.ifa_netmask
            else { continue }

            let host = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if let broadcast = IPv4Broadcast.address(host: host, netmask: netmask) {
                addresses.append(broadcast)
            }
        }
        return addresses
    }

    // MARK: - Receiving

    private static func replies(from handle: Int32) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.justinlascelle.jellyshark.discovery")
            let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)

            source.setEventHandler {
                // A discovery reply is a few hundred bytes; this is just headroom.
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = buffer.withUnsafeMutableBytes { recv(handle, $0.baseAddress, $0.count, 0) }
                if count > 0 {
                    continuation.yield(Data(buffer.prefix(count)))
                    return
                }

                // A zero-length datagram is legal UDP and simply carries nothing.
                guard count < 0 else { return }

                // The read source is level-triggered, so a persistent error would
                // re-arm this handler forever and spin the queue. Only "nothing left
                // to read" on a non-blocking socket, and an interrupted call, are
                // worth waiting out; anything else ends the round.
                let failure = errno
                guard failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR else {
                    continuation.finish()
                    return
                }
            }

            // The cancel handler owns the descriptor. Closing it anywhere else could
            // race the source's own read and, worse, close a number the OS has since
            // handed to somebody else.
            source.setCancelHandler { close(handle) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}

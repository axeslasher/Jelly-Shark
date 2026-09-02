import Foundation

/// Computes IPv4 subnet broadcast addresses. Split out from the socket, and kept
/// pure, so the arithmetic is testable on the host — the interface enumeration that
/// feeds it is not.
enum IPv4Broadcast {
    /// The directed broadcast address for the subnet `host` sits on: the host address
    /// with every bit the netmask doesn't cover set to 1.
    ///
    /// Byte order doesn't matter — this is bitwise, so network-order in gives
    /// network-order out.
    ///
    /// Returns `nil` where a directed broadcast is meaningless: a /32, whose broadcast
    /// address would be the host itself, and an all-zero mask, whose broadcast address
    /// is 255.255.255.255, which is probed unconditionally anyway.
    static func address(host: UInt32, netmask: UInt32) -> UInt32? {
        guard netmask != 0, netmask != .max else { return nil }
        return host | ~netmask
    }
}

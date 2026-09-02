import Foundation
import JellyfinAPI

/// The Jellyfin auto-discovery wire protocol.
///
/// Verified against the server's own implementation rather than against the client
/// docs — `src/Jellyfin.Networking/AutoDiscoveryHost.cs` on jellyfin master, which is
/// where the old `Emby.Server.Implementations/Udp/UdpServer.cs` ended up:
///
/// - the server binds UDP 7359 on `IPAddress.Any`, and the port is not configurable;
/// - it replies to any datagram whose UTF-8 text *contains* "who is JellyfinServer?",
///   compared with `StringComparison.OrdinalIgnoreCase`, so the bare string with no
///   framing is what it wants;
/// - it answers with `JsonSerializer.SerializeToUtf8Bytes(ServerDiscoveryInfo)` using
///   default options, which means PascalCase keys — exactly what the SDK's DTO
///   decodes — and sends it from its own `:7359` back to our source port. That last
///   detail is why the transport underneath has to be an unconnected socket.
enum ServerDiscoveryMessage {
    /// The port the server listens on.
    static let port: UInt16 = 7359

    /// The probe text. The server substring-matches it, case-insensitively.
    static let probe = "who is JellyfinServer?"

    /// The probe datagram: the probe text as UTF-8, with no framing of any kind.
    static var probePayload: Data {
        Data(probe.utf8)
    }

    /// Decodes one reply datagram, or `nil` when it isn't a usable discovery reply.
    ///
    /// A UDP broadcast port hears whatever else is shouting on the network, so a
    /// datagram that doesn't decode is an ordinary event, not an error.
    static func decode(_ datagram: Data) -> DiscoveredServer? {
        guard let info = try? JSONDecoder().decode(ServerDiscoveryInfo.self, from: datagram) else { return nil }
        return DiscoveredServer(info)
    }
}

/// Accumulates reply datagrams into a de-duplicated, ordered result.
struct DiscoveredServerCollector {
    private(set) var servers: [DiscoveredServer] = []
    private var seenIDs: Set<String> = []

    /// A server answers once per broadcast address it hears the probe on, so on a
    /// multi-homed host duplicates are the norm rather than the exception. The first
    /// reply wins: it came back over whichever path was quickest to answer.
    mutating func accept(_ datagram: Data) {
        guard let server = ServerDiscoveryMessage.decode(datagram),
              seenIDs.insert(server.id).inserted
        else { return }

        servers.append(server)
    }
}

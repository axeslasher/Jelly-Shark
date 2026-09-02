import Foundation
import JellyfinAPI

/// A Jellyfin server that answered the local-network discovery probe.
///
/// Carries just enough for a pick-list entry: `address` is the base URL the server
/// itself told us to use, so selecting one can fill in the connect form without any
/// further lookup.
public struct DiscoveredServer: Sendable, Hashable, Identifiable {
    /// The server's own identifier (`ServerDiscoveryInfo.Id`), and the dedup key.
    public let id: String

    /// The server's friendly name, or `address` when the server sent none.
    public let name: String

    /// Base URL of the server, e.g. `http://192.168.1.50:8096`.
    public let address: String

    public init(id: String, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }
}

extension DiscoveredServer {
    /// Maps a decoded reply, dropping the ones no pick-list entry can be built from.
    ///
    /// Every field of the SDK's DTO is optional, but the server always sends `Address`
    /// and `Id` — `AutoDiscoveryHost.RespondToV2Message` bails out without replying at
    /// all when it can't determine an address — so a reply missing either is malformed
    /// rather than merely sparse. `Name` is likewise always populated in practice;
    /// falling back to the address keeps a blank row out of the list if some fork or
    /// future version sends an empty one.
    init?(_ info: ServerDiscoveryInfo) {
        guard let id = info.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let address = info.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty
        else { return nil }

        let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: id, name: name.isEmpty ? address : name, address: address)
    }
}

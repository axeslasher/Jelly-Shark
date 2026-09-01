import Foundation
import OSLog

/// Finds Jellyfin servers on the local network.
///
/// One shot: broadcast the Jellyfin discovery probe, collect replies for a short
/// window, return what answered. It never throws. A denied local-network permission,
/// a socket the OS refuses to open, and a network where nothing answers all resolve to
/// an empty result, because typing the server address by hand has to stay open as the
/// fallback in every one of those cases.
public struct ServerDiscovery: Sendable {
    /// Whether discovery can work on this platform at all.
    ///
    /// visionOS gates UDP broadcast behind `com.apple.developer.networking.multicast`,
    /// a managed entitlement that has to be requested from and granted by Apple
    /// (TN3151, TN3179). Until that request is made, discovery is Apple TV only, and
    /// callers should hide the pick-list on visionOS rather than show one that can
    /// never fill. tvOS has no local-network privacy at all, so nothing gates it there.
    public static var isAvailable: Bool {
        #if os(visionOS)
            false
        #else
            true
        #endif
    }

    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Discovery")

    private let transport: any DiscoveryTransport
    private let window: any DiscoveryWindow

    public init() {
        self.init(transport: BroadcastUDPSocket(), window: TaskSleepWindow())
    }

    init(transport: any DiscoveryTransport, window: any DiscoveryWindow) {
        self.transport = transport
        self.window = window
    }

    /// Broadcasts the discovery probe and returns the servers that answer within
    /// `duration`.
    ///
    /// Results are de-duplicated by server id and ordered by first reply. If the
    /// calling task is cancelled the round ends early, the socket is torn down, and
    /// whatever had already been collected is returned.
    public func discoverServers(within duration: Duration = .seconds(2)) async -> [DiscoveredServer] {
        guard Self.isAvailable, !Task.isCancelled else { return [] }

        let replies: AsyncStream<Data>
        do {
            replies = try transport.probe(
                payload: ServerDiscoveryMessage.probePayload,
                port: ServerDiscoveryMessage.port,
            )
        } catch {
            Self.logger.debug("Discovery probe not sent: \(error.reason, privacy: .public) (errno \(error.code))")
            return []
        }

        let collected = ReplyCollector()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await datagram in replies {
                    await collected.accept(datagram)
                }
            }
            group.addTask { await window.wait(duration) }

            // Whichever finishes first ends the round: the window elapsing, the
            // transport giving up, or the caller cancelling us. Cancelling the rest
            // terminates the reply stream, which is what closes the socket.
            _ = await group.next()
            group.cancelAll()
        }
        return await collected.servers
    }
}

/// Shared between the collecting child task and the caller, so a window that elapses —
/// or a cancellation — still hands back what has already arrived.
private actor ReplyCollector {
    private var collector = DiscoveredServerCollector()

    var servers: [DiscoveredServer] {
        collector.servers
    }

    func accept(_ datagram: Data) {
        collector.accept(datagram)
    }
}

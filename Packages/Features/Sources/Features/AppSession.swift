import Foundation
import Observation
import JellyfinKit

/// Shared session state for the app
///
/// Holds the active Jellyfin client after a successful server connection
/// so any feature (browsing, playback, etc.) can access it via the
/// SwiftUI environment.
@Observable
@MainActor
public final class AppSession {
    /// The active, authenticated Jellyfin client, if connected
    public private(set) var client: (any JellyfinClientProtocol)?

    /// Whether there is an authenticated connection to a server
    public var isConnected: Bool {
        client?.isAuthenticated ?? false
    }

    public init() {}

    /// Store the client after a successful connection
    public func setClient(_ client: any JellyfinClientProtocol) {
        self.client = client
    }

    /// Clear the client on disconnect
    public func clearClient() {
        client = nil
    }
}

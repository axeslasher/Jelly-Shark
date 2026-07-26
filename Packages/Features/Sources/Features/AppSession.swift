// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import JellyfinKit
import Observation

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

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

/// A person credited on a media item (cast or crew).
///
/// Created from the SDK's `BaseItemPerson` via the adapter layer. Person IDs are
/// item IDs in Jellyfin, so a headshot URL can be built with the standard image
/// endpoint when `primaryImageTag` is present.
public struct CastMember: Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for the person (usable as an item ID for image URLs)
    public let id: String

    /// Display name of the person
    public let name: String

    /// Character name for actors (e.g., "Neo"); nil for most crew
    public let role: String?

    /// Credit kind (e.g., "Actor", "Director", "Writer")
    public let kind: String

    /// Primary image tag, or nil when the person has no headshot
    public let primaryImageTag: String?

    public init(
        id: String,
        name: String,
        role: String? = nil,
        kind: String,
        primaryImageTag: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.kind = kind
        self.primaryImageTag = primaryImageTag
    }
}

public extension CastMember {
    /// Whether `id` is a real server ID (fetchable, navigable) rather than the
    /// adapter's position-based "person-N" fallback for servers that omit
    /// person IDs. Real Jellyfin IDs are GUIDs, so the prefix can't collide.
    var hasServerId: Bool {
        !id.isEmpty && !id.hasPrefix("person-")
    }
}

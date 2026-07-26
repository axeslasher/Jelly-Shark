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

/// One chapter of a playable item
///
/// Jellyfin's `ChapterInfo` carries a start position and, when the server has
/// extracted chapter images, an image tag. Chapter images are addressed by the
/// chapter's position in the server's chapter array, so `imageIndex` preserves
/// that position even when malformed siblings are dropped by the adapter.
public struct Chapter: Sendable, Equatable, Hashable {
    /// Display name; the adapter substitutes "Chapter N" when the server
    /// omits one
    public let name: String

    /// Start position in ticks (1 tick = 100ns)
    public let startTicks: Int64

    /// The chapter's position in the server's chapter array — the `{index}`
    /// path segment of the chapter image endpoint
    public let imageIndex: Int

    /// Cache-busting tag for the chapter image; nil when the server has not
    /// extracted an image for this chapter
    public let imageTag: String?

    /// Start position in seconds
    public var startSeconds: Double {
        Double(startTicks) / 10_000_000
    }

    public init(name: String, startTicks: Int64, imageIndex: Int, imageTag: String? = nil) {
        self.name = name
        self.startTicks = startTicks
        self.imageIndex = imageIndex
        self.imageTag = imageTag
    }
}

/// Ancillary per-item data resolved alongside playback — trickplay, chapters,
/// and cast ride the same fields-scoped item fetch
///
/// Cast is fetched here rather than read off the launching `MediaItem`
/// because playback can start from shelf items whose list fetches never
/// request the People field.
public struct PlaybackExtras: Sendable, Equatable {
    /// Seek-preview tile metadata, when the server has trickplay data
    public let trickplay: TrickplayManifest?

    /// The item's chapters, empty when the server reports none
    public let chapters: [Chapter]

    /// The item's cast and crew, empty when the server reports none
    public let people: [CastMember]

    public init(
        trickplay: TrickplayManifest? = nil,
        chapters: [Chapter] = [],
        people: [CastMember] = [],
    ) {
        self.trickplay = trickplay
        self.chapters = chapters
        self.people = people
    }
}

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

/// Metadata for one image an item carries on the server (GET
/// /Items/{itemId}/Images) — the pixel dimensions callers need to judge
/// whether an image can fill a large slot before requesting it.
public struct ItemImageInfo: Sendable, Equatable, Hashable {
    public let imageType: ImageType

    /// Pixel width of the stored image (nil when the server doesn't know)
    public let width: Int?

    /// Pixel height of the stored image (nil when the server doesn't know)
    public let height: Int?

    public init(imageType: ImageType, width: Int? = nil, height: Int? = nil) {
        self.imageType = imageType
        self.width = width
        self.height = height
    }
}

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

@testable import DesignSystem
@testable import Features
@testable import JellyfinKit
import SwiftUI
import Testing

@Suite("Features Tests")
struct FeaturesTests {
    @Suite("RootView Tests")
    struct RootViewTests {
        @Test("RootView initializes")
        func rootViewInit() {
            let view = RootView()
            // View creates without crashing
            _ = view
        }
    }

    @Suite("MediaDetailView Tests")
    struct MediaDetailViewTests {
        @Test("MediaDetailView displays item")
        func mediaDetailViewInit() {
            let item = MediaItem(
                id: "test-1",
                name: "Test Movie",
                type: .movie,
                productionYear: 2024,
            )
            let view = MediaDetailView(item: item)
            _ = view
        }
    }

    @Suite("SettingsView Tests")
    struct SettingsViewTests {
        @Test("SettingsView initializes")
        func settingsViewInit() {
            let view = SettingsView()
            _ = view
        }
    }
}

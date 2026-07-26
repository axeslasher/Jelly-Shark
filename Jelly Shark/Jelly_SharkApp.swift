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

//
//  Jelly_SharkApp.swift
//  Jelly Shark
//
//  Created by Justin Lascelle on 1/6/26.
//

import DesignSystem
import Features
import SwiftUI

@main
struct Jelly_SharkApp: App {
    init() {
        // Size the shared cache for encoded poster/backdrop artwork bytes.
        // Both artwork paths land in it: `ArtworkLoader` fetches through its
        // own session with `urlCache = .shared` (decoded images live in its
        // own bounded NSCache tiers), and `TrimmedLogoImage` fetches through
        // `URLSession.shared`. The memory tier only shortcuts re-decodes after a
        // decoded-tier eviction — encoded bytes are ~10-20x smaller than their
        // bitmaps, so 16MB covers plenty and the RAM belongs to decoded images.
        URLCache.shared.memoryCapacity = 16 * 1024 * 1024
        URLCache.shared.diskCapacity = 256 * 1024 * 1024
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // The theme system is committed to dark surfaces with light
                // type; declaring the app dark keeps system-drawn chrome
                // (focus platters, materials, glass) in its dark variants
                // instead of following the viewer's system appearance.
                .preferredColorScheme(.dark)
        }
    }
}

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
        // Size the shared cache for encoded poster/backdrop artwork bytes. It
        // backs `URLSession.shared`, which is what `ArtworkLoader` (decoded
        // images live in its own bounded NSCache tier) and `TrimmedLogoImage`
        // fetch through.
        URLCache.shared.memoryCapacity = 64 * 1024 * 1024
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

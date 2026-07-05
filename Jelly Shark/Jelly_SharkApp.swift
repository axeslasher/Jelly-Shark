//
//  Jelly_SharkApp.swift
//  Jelly Shark
//
//  Created by Justin Lascelle on 1/6/26.
//

import SwiftUI
import Features
import DesignSystem

@main
struct Jelly_SharkApp: App {
    init() {
        // Artwork loads through AsyncImage's shared URL session; give the
        // shared cache enough room for poster and backdrop images.
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

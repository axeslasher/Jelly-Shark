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
        // Size the shared cache for poster/backdrop artwork. It backs
        // `URLSession.shared` (e.g. TrimmedLogoImage) and the OS-26 AsyncImage
        // path directly; on OS 27, where AsyncImage uses the framework's own
        // image loader, RootView routes artwork through an explicit session
        // bound to this same cache (see `artworkImageSession`) so the budget
        // still applies.
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

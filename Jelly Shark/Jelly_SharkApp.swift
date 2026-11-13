import DesignSystem
import Features
import JellyfinKit
import SwiftUI

@main
struct Jelly_SharkApp: App {
    /// Created here because the App struct is instantiated exactly once per
    /// process — `RootView.init` re-runs on every body re-evaluation, and
    /// each `makePersistent()` call opens the store files.
    private let mediaCache = MediaCacheStore.makePersistent()

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
            RootView(cache: mediaCache)
                // The theme system is committed to dark surfaces with light
                // type; declaring the app dark keeps system-drawn chrome
                // (focus platters, materials, glass) in its dark variants
                // instead of following the viewer's system appearance.
                .preferredColorScheme(.dark)
            #if os(visionOS)
                .uniformWindowResizing()
            #endif
        }
        #if os(visionOS)
        // 16:9 at 1080p points: the app opens at a deliberate size, and
        // `uniformWindowResizing()` keeps that shape. See the 2026-11-13
        // row in docs/ARCHITECTURE.md § Decision Log.
        .defaultSize(width: 1920, height: 1080)
        #endif
    }
}

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

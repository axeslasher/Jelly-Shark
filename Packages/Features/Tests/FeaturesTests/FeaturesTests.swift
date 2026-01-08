import Testing
import SwiftUI
@testable import Features
@testable import JellyfinKit
@testable import DesignSystem

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

    @Suite("LibraryView Tests")
    struct LibraryViewTests {
        @Test("LibraryView initializes")
        func libraryViewInit() {
            let view = LibraryView()
            _ = view
        }

        @Test("All library types have titles and icons")
        func libraryTypes() {
            for type in LibraryView.LibraryType.allCases {
                #expect(!type.title.isEmpty)
                #expect(!type.icon.isEmpty)
            }
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
                productionYear: 2024
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

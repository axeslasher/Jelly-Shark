import SwiftUI
import DesignSystem

/// The root view of the application
/// Handles top-level navigation and theme application
public struct RootView: View {
    @State private var themeManager = ThemeManager.shared
    @State private var selectedTab: Tab = .home

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(Tab.home)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "rectangle.stack.fill")
                }
                .tag(Tab.library)

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(Tab.search)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
        }
        .withThemeEnvironment(themeManager)
    }
}

// MARK: - Tab

extension RootView {
    enum Tab: Hashable {
        case home
        case library
        case search
        case settings
    }
}

// MARK: - Preview

#Preview {
    RootView()
}

import SwiftUI
import DesignSystem
import JellyfinKit

/// The root view of the application
/// Handles top-level navigation and theme application
public struct RootView: View {
    @State private var themeManager = ThemeManager.shared
    @State private var session = AppSession()
    @State private var connectionViewModel = ServerConnectionViewModel()
    @State private var selectedTab: AppTab = .home

    /// One navigation path per tab, owned here (the tab views don't create
    /// their own `NavigationStack`s) so `tabSelection` can pop a stack to root
    /// before a tab switch. All pushes are value-based for the same reason —
    /// view-destination links can't be popped programmatically.
    @State private var tabPaths: [AppTab: NavigationPath] = [:]

    public init() {}

    /// Wraps `selectedTab` to work around a tvOS `sidebarAdaptable` bug: if the
    /// outgoing tab's `NavigationStack` has a pushed view (e.g. a media
    /// detail), the TabView commits the new selection but never removes the
    /// pushed screen — it lingers as a stale UIKit-level presentation. State
    /// surgery (identity resets, pre-switch teardown) doesn't dislodge it; the
    /// only thing UIKit reliably honors is a real navigation pop. So the setter
    /// pops the outgoing stack to root via its path, waits for the pop to
    /// land, then commits the switch. Tabs with nothing pushed switch
    /// immediately.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard newValue != selectedTab else { return }
                let outgoing = selectedTab
                if let path = tabPaths[outgoing], !path.isEmpty {
                    tabPaths[outgoing] = NavigationPath()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        selectedTab = newValue
                    }
                } else {
                    selectedTab = newValue
                }
            }
        )
    }

    private func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { tabPaths[tab, default: NavigationPath()] },
            set: { tabPaths[tab] = $0 }
        )
    }

    public var body: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                navigationRoot(for: .home) {
                    HomeView()
                }
            }

            // One tab per server library, using the user's display name (which
            // they may have renamed, e.g. "Films") and an icon derived from the
            // library's collection type (which renames don't touch).
            //
            // Plain string labels on purpose: the tvOS sidebar normalizes label
            // styling — custom fonts/colors on Tab labels and TabSection
            // headers compile but are ignored at runtime (verified). Theming
            // the nav beyond `.tint` means replacing the system sidebar, which
            // is the navigation component-variant work, not a token tweak.
            if !connectionViewModel.libraries.isEmpty {
                TabSection("Libraries") {
                    ForEach(connectionViewModel.libraries) { library in
                        Tab(
                            library.name,
                            systemImage: library.systemImageName,
                            value: AppTab.library(library.id)
                        ) {
                            navigationRoot(for: .library(library.id)) {
                                LibraryItemsView(library: library)
                            }
                        }
                    }
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                navigationRoot(for: .search) {
                    SearchView()
                }
            }

            // In its own (headerless) section: the tvOS sidebar hoists loose
            // tabs above TabSections regardless of declaration order, so
            // Settings must be section-anchored to sit below the libraries.
            TabSection {
                Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                    navigationRoot(for: .settings) {
                        SettingsView()
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .withThemeEnvironment(themeManager)
        .environment(session)
        .environment(connectionViewModel)
        .task {
            // Attach here (not just in Settings) so a restored client is
            // published app-wide even if the user never opens Settings
            connectionViewModel.attach(session: session)
            await connectionViewModel.restoreSession()
        }
        // If the selected library tab disappears (disconnect clears the list,
        // or the server removed a library), fall back to Home rather than
        // leaving the selection pointing at a tab that no longer exists.
        .onChange(of: connectionViewModel.libraries) { _, libraries in
            if case .library(let id) = selectedTab,
               !libraries.contains(where: { $0.id == id })
            {
                selectedTab = .home
            }
        }
    }

    /// The per-tab `NavigationStack`, bound to this tab's path, with the
    /// media-detail and person-detail destinations registered at the root so
    /// every shelf/grid card (and details pushed from other details) resolves
    /// through it.
    private func navigationRoot(
        for tab: AppTab,
        @ViewBuilder content: () -> some View
    ) -> some View {
        NavigationStack(path: path(for: tab)) {
            content()
                .navigationDestination(for: MediaItem.self) { item in
                    MediaDetailView(item: item)
                }
                .navigationDestination(for: CastMember.self) { member in
                    PersonDetailView(member: member)
                }
        }
    }
}

// MARK: - Tab

extension RootView {
    /// Top-level navigation destinations. Library tabs are dynamic — one per
    /// server library, keyed by the library's id.
    enum AppTab: Hashable {
        case home
        case library(String)
        case search
        case settings
    }
}

// MARK: - Preview

#Preview {
    RootView()
}

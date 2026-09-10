import DesignSystem
import JellyfinKit
import SwiftUI

/// The root view of the application
/// Handles top-level navigation and theme application
public struct RootView: View {
    @State private var themeManager = ThemeManager.shared
    @State private var session = AppSession()
    @State private var connectionViewModel: ServerConnectionViewModel
    @State private var homePreferences = HomePreferences()
    @State private var playbackPreferences = PlaybackPreferences()
    @State private var selectedTab: AppTab = .home

    /// Home's view models and UI state, owned here (not in `HomeView`) so
    /// tvOS tearing the tab down on switch loses neither the fetched data
    /// nor where the viewer was standing in it (#236 § 3).
    @State private var homeViewModel = HomeViewModel()
    @State private var genreShelves = GenreShelvesViewModel()
    @State private var affinityShelves = AffinityShelvesViewModel()
    @State private var homeUI = HomeUIState()

    /// Collects the reasons Home's content has gone stale, so a mutation
    /// made anywhere in the app is not lost while Home is off screen.
    @State private var refreshCoordinator = ContentRefreshCoordinator()

    /// One navigation path per tab, owned here (the tab views don't create
    /// their own `NavigationStack`s) so `tabSelection` can pop a stack to root
    /// before a tab switch. All pushes are value-based for the same reason —
    /// view-destination links can't be popped programmatically.
    @State private var tabPaths: [AppTab: NavigationPath] = [:]

    #if os(tvOS)
        /// The in-flight deferred tab switch (see `tabSelection`). Held so a
        /// second tab press within the pop-settle window can cancel the first
        /// before it commits — otherwise the stale, already-superseded target
        /// wakes last and clobbers the selection ("I pressed Search but it
        /// jumped to Home").
        @State private var pendingSwitch: Task<Void, Never>?

        /// Distinguishes the current deferred switch from a superseded one, so a
        /// late task cannot clear a newer switch's handle.
        @State private var switchGeneration = 0
    #endif

    /// - Parameter cache: the app's metadata cache; nil (previews, tests)
    ///   runs the whole connection flow cache-less
    public init(cache: MediaCacheStore? = nil) {
        _connectionViewModel = State(initialValue: ServerConnectionViewModel(cache: cache))
    }

    /// Wraps `selectedTab` to work around a tvOS `sidebarAdaptable` bug: if the
    /// outgoing tab's `NavigationStack` has a pushed view (e.g. a media
    /// detail), the TabView commits the new selection but never removes the
    /// pushed screen — it lingers as a stale UIKit-level presentation. State
    /// surgery (identity resets, pre-switch teardown) doesn't dislodge it; the
    /// only thing UIKit reliably honors is a real navigation pop. So the setter
    /// pops the outgoing stack to root via its path, waits for the pop to
    /// land, then commits the switch. Tabs with nothing pushed switch
    /// immediately.
    ///
    /// The bug belongs to the sidebar representation, which visionOS no longer
    /// uses, so that platform switches straight away — no pop-settle stall,
    /// and a tab keeps its place in its stack when you come back to it.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard newValue != selectedTab else { return }
                #if os(tvOS)
                    // A new selection supersedes any deferred switch still
                    // waiting on a pop; cancel it so only the latest target
                    // can commit.
                    pendingSwitch?.cancel()
                    pendingSwitch = nil
                    let outgoing = selectedTab
                    if let path = tabPaths[outgoing], !path.isEmpty {
                        tabPaths[outgoing] = NavigationPath()
                        switchGeneration &+= 1
                        let generation = switchGeneration
                        pendingSwitch = Task { @MainActor in
                            try? await Task.sleep(for: Self.popSettle)
                            guard !Task.isCancelled, generation == switchGeneration else { return }
                            selectedTab = newValue
                            // Clear the handle so "a switch is in flight" stops being true.
                            // Guarded by the generation so a stale task cannot clear a newer
                            // switch's handle out from under it (#236 § 4).
                            pendingSwitch = nil
                        }
                    } else {
                        selectedTab = newValue
                    }
                #else
                    selectedTab = newValue
                #endif
            },
        )
    }

    private func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { tabPaths[tab, default: NavigationPath()] },
            set: { tabPaths[tab] = $0 },
        )
    }

    /// Whether Home may refresh right now.
    ///
    /// Three conditions, not one. `tabSelection` empties the outgoing tab's
    /// path synchronously and only commits `selectedTab` after the settle, so
    /// leaving Home with a detail pushed makes the first two transiently true
    /// while the viewer is on their way out. `pendingSwitch` is precisely the
    /// "we are leaving" signal, so it closes that window at the source
    /// (#236 § 4). Task 7 makes a completed switch clear the handle; without
    /// that this is false forever after the first deferred switch.
    static func homeRefreshEligible(
        selectedTab: AppTab,
        homePathIsEmpty: Bool,
        hasPendingSwitch: Bool,
    ) -> Bool {
        selectedTab == .home && homePathIsEmpty && !hasPendingSwitch
    }

    private var isHomeRefreshEligible: Bool {
        #if os(tvOS)
            let switching = pendingSwitch != nil
        #else
            let switching = false
        #endif
        return Self.homeRefreshEligible(
            selectedTab: selectedTab,
            homePathIsEmpty: tabPaths[.home, default: NavigationPath()].isEmpty,
            hasPendingSwitch: switching,
        )
    }

    public var body: some View {
        TabView(selection: tabSelection) {
            homeTab

            // `TabSection` is a feature of `sidebarAdaptable`, not of TabView
            // at large: it declares a secondary hierarchy that only the
            // sidebar representation can draw. So the grouping is tvOS-only.
            // On visionOS's ornament a section collapses to a single stub tab
            // (labeled, iconless, and with its children unreachable — a
            // headerless one draws as a blank slot).
            //
            // The two platforms' library navigation now diverges deliberately
            // (#138, and #36 needs to know). tvOS keeps one tab per library:
            // its sidebar scrolls, so a long list costs nothing but a scroll,
            // and a library one press from anywhere is the right 10-foot
            // shape. visionOS cannot afford that — its ornament silently drops
            // tabs past a limit observed at 8, so enough libraries pushed
            // Settings, declared last, out of existence. There, every library
            // lives behind one Libraries tab, which fixes the ornament at four
            // entries no matter what the server exposes.
            #if os(tvOS)
                if !connectionViewModel.libraries.isEmpty {
                    TabSection("Libraries") {
                        libraryTabs
                    }
                }

                searchTab

                // In its own (headerless) section so the loose-tab hoisting
                // above doesn't lift Settings out of its place below the
                // libraries.
                TabSection {
                    settingsTab
                }
            #else
                // Declared in the order the ornament shows them, which is
                // also the order the tvOS sidebar settles on — it hoists loose
                // tabs above sections, so Search sits above the libraries
                // there too.
                searchTab

                // Withdrawn when the server exposes no browsable library,
                // mirroring the tvOS section above: an always-present tab
                // would open on an empty page with nothing to look at or
                // select. `tabSelection` is moved off it below if the list
                // empties while the viewer is standing in it.
                if !connectionViewModel.libraries.isEmpty {
                    librariesTab
                }

                settingsTab
            #endif
        }
        // tvOS only: the sidebar-adaptable split suits a 10-foot layout, where
        // a focus-driven sidebar that expands on demand is the native nav
        // shape. visionOS keeps the system default — the floating tab bar
        // ornament outside the window — which is that platform's native shape
        // and doesn't spend window width on a permanent rail.
        #if os(tvOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        .withThemeEnvironment(themeManager)
        .environment(session)
        .environment(connectionViewModel)
        .environment(homePreferences)
        .environment(playbackPreferences)
        .environment(refreshCoordinator)
        .environment(\.openSettings, OpenSettingsAction {
            tabSelection.wrappedValue = .settings
        })
        .environment(\.pushMediaDetail, PushMediaDetailAction { item in
            var path = tabPaths[selectedTab, default: NavigationPath()]
            path.append(item)
            tabPaths[selectedTab] = path
        })
        .task {
            // Attach here (not just in Settings) so a restored client is
            // published app-wide even if the user never opens Settings
            connectionViewModel.attach(session: session)
            await connectionViewModel.restoreSession()

            #if DEBUG
                // Test hook: auto-connect to a server from the environment
                // (pass via `simctl launch` with SIMCTL_CHILD_-prefixed vars)
                // so UI automation can reach a connected state without
                // driving the connection form
                if case .disconnected = connectionViewModel.state,
                   let server = ProcessInfo.processInfo.environment["JS_AUTOCONNECT_SERVER"]
                {
                    connectionViewModel.serverURL = server
                    connectionViewModel.username = ProcessInfo.processInfo.environment["JS_AUTOCONNECT_USER"] ?? ""
                    connectionViewModel.password = ProcessInfo.processInfo.environment["JS_AUTOCONNECT_PASSWORD"] ?? ""
                    await connectionViewModel.connect()
                }
            #endif
        }
        // Home's initial load is owned here, with the view models, not by
        // `HomeView`'s own `.task`. On device that task was cancelled about a
        // second after connect, mid fan-out, and never restarted, so every
        // cold launch's first load died and the drain redid it (#236 device
        // row 1). The likely trigger — unverified — is the tab set changing as
        // libraries and counts arrive, which rebuilds the tab's content and
        // cancels the old task while its replacement finds `needsLoad` already
        // consumed. A task on the root survives whatever the tab does.
        .task(id: session.isConnected) {
            // The update that flips `isConnected` can also change `libraries`
            // (restore publishes the cached list, then the fresh one, in one
            // turn). Its `onChange` posts `.libraries` in that same update, and
            // this task's first synchronous stretch can run before it does —
            // reading a revision the post has not reached yet, so the load
            // covers the change but never retires the reason, and the drain
            // redoes the whole load (#236 device row 1). One yield lets every
            // handler of this update land before anything here is read.
            await Task.yield()
            guard !Task.isCancelled else { return }
            homeViewModel.attach(
                client: session.client,
                libraries: connectionViewModel.libraries,
                cache: session.scopedCache,
                userState: session.userState,
            )
            // Read before the load: reasons raised before it are covered by
            // it, anything posted while it ran is not (§ 8).
            let revisionAtStart = refreshCoordinator.revision
            let didLoad = await homeViewModel.load()

            // Before any affinity fetch: a saved-off preference must not
            // spend a request at launch. `HomeView`'s toggle task runs later.
            await affinityShelves.setEnabled(homePreferences.showsDiscoveryShelves)
            affinityShelves.attach(
                client: session.client,
                libraries: connectionViewModel.libraries,
                cache: session.scopedCache,
            )
            // Cached rows first, with no fingerprint check and no network, so
            // they are in the focus graph from the first frame they could be
            // — and never queued behind the genre fetch below (#86 § 9.1).
            await affinityShelves.hydrate()

            genreShelves.attach(client: session.client, libraries: connectionViewModel.libraries)
            // Concurrent: neither has anything to say to the other.
            async let genres: Void = genreShelves.load()
            async let affinity: Void = affinityShelves.validate()
            _ = await (genres, affinity)

            // Flipping this is what releases Home's drain — so only a pass
            // that had a client may flip it. This task runs once with
            // `isConnected == false` on every cold launch; that pass takes
            // `load()`'s no-client branch and settles nothing, and opening the
            // gate for it let the drain supersede the real load (#236 § 8.1).
            refreshCoordinator.isInitialLoadSettled = session.client != nil
            // Seed the floor only if a load actually ran; stamping the
            // timestamp for a guarded-out call would disable the
            // external-client fallback forever.
            guard didLoad else { return }
            refreshCoordinator.completeInitialLoad(
                revisionAtStart: revisionAtStart,
                succeeded: homeViewModel.lastLoadOutcome == .succeeded,
                now: .now,
            )
        }
        // The hoisted page state now outlives a disconnect, so a signed-out
        // Home no longer gets torn down with it: without this, a sign-out
        // while Home is unmounted (tvOS tears its view down on tab switch)
        // leaves the previous user's shelves sitting in `homeViewModel` and
        // `genreShelves`, and the next signed-in user's Home paints them for
        // one frame before its own load replaces them (#236 § 14.1). A fresh
        // instance carries no data to leak and no scroll/focus memory to
        // misapply to a different library. Not gated on the *new* session
        // connecting — nothing observes `isConnected` going true here, so
        // resetting exactly on the false edge is enough and avoids
        // discarding a session's state while it's still active.
        .onChange(of: session.isConnected) { _, isConnected in
            guard !isConnected else { return }
            homeViewModel = HomeViewModel()
            genreShelves = GenreShelvesViewModel()
            affinityShelves = AffinityShelvesViewModel()
            homeUI = HomeUIState()
            // The fresh page owes its own initial load, and the § 8.1 gate is
            // what keeps a drain from superseding it.
            refreshCoordinator.isInitialLoadSettled = false
            // The disconnect tore down any presented player with it, so a
            // ticket registered at presentation may never get its stop task.
            // One of those blocks every future drain for the process.
            refreshCoordinator.clearPlaybackSessions()
        }
        // `UserStateStore` lives in JellyfinKit and cannot know about the
        // coordinator, so it publishes a counter and the translation happens at
        // the Features boundary. Every successful mutation from every surface
        // already funnels through `confirm`/`recordPosition`, so no producer can
        // silently forget to post (#236 § 5.2). Not only surfaces:
        // `UserStateStore`'s position guard expires about 30s after playback
        // and bumps the revision too, so that expiry posts as well.
        .onChange(of: isHomeRefreshEligible) { _, eligible in
            // Marks a real departure, so Home's next appearance can tell a
            // tab return from an in-place rebuild (see `HomeUIState`).
            if !eligible {
                homeUI.wasOffScreen = true
            }
        }
        .onChange(of: session.userState.mutationRevision) { _, _ in
            refreshCoordinator.post(.watchState)
        }
        // If the selected library tab disappears (disconnect clears the list,
        // or the server removed a library), fall back to Home rather than
        // leaving the selection pointing at a tab that no longer exists.
        //
        // The `.libraries` arm is unreachable on tvOS, which never selects that
        // tab; it costs that platform nothing and keeps the rule in one place.
        .onChange(of: connectionViewModel.libraries) { _, libraries in
            refreshCoordinator.post(.libraries)
            switch selectedTab {
            case let .library(id) where !libraries.contains(where: { $0.id == id }):
                selectedTab = .home
            case .libraries where libraries.isEmpty:
                selectedTab = .home
            default:
                break
            }

            #if !os(tvOS)
                // The grid is the Libraries stack's root, so a changed library
                // set invalidates whatever was pushed from it: a profile
                // switch or a server swap would otherwise leave that tab
                // sitting inside a `LibraryItemsView` for a library the new
                // session has never heard of, which the viewer only discovers
                // on returning to the tab. Any change resets it, not just an
                // emptying one — `onChange` fires only when the set actually
                // differs, so a refresh that returns the same libraries leaves
                // a pushed grid alone.
                //
                // tvOS is deliberately outside this: its libraries are tabs,
                // each with its own stack that the switch above already
                // handles, and writing this key there would put an entry in
                // `tabPaths` for a tab that platform never declares.
                tabPaths[.libraries] = NavigationPath()
            #endif
        }
    }

    // MARK: - Tab content

    //
    // Declared apart from `body` so the platform branch above chooses only how
    // the tabs are *grouped* — the tabs themselves stay identical, and tvOS
    // can't drift as visionOS is adapted.

    private var homeTab: some TabContent<AppTab> {
        Tab("Home", systemImage: "house.fill", value: AppTab.home) {
            navigationRoot(for: .home) {
                HomeView(
                    viewModel: homeViewModel,
                    genreShelves: genreShelves,
                    affinityShelves: affinityShelves,
                    ui: homeUI,
                    isEligible: isHomeRefreshEligible,
                )
            }
        }
    }

    #if os(tvOS)
        /// One tab per server library, using the user's display name (which
        /// they may have renamed, e.g. "Films") and an icon derived from the
        /// library's collection type (which renames don't touch).
        ///
        /// tvOS only since #138 — visionOS collapses the same libraries into
        /// `librariesTab`. The platforms are allowed to differ here because
        /// their navigation containers do: a sidebar scrolls, an ornament
        /// silently truncates.
        ///
        /// Plain string labels on purpose: the tvOS sidebar normalizes label
        /// styling — custom fonts/colors on Tab labels and TabSection headers
        /// compile but are ignored at runtime (verified). Theming the nav
        /// beyond `.tint` means replacing the system sidebar, which is the
        /// navigation component-variant work, not a token tweak.
        private var libraryTabs: some TabContent<AppTab> {
            ForEach(connectionViewModel.libraries) { library in
                Tab(
                    library.name,
                    systemImage: library.systemImageName,
                    value: AppTab.library(library.id),
                ) {
                    navigationRoot(for: .library(library.id)) {
                        // No `libraryOptions`: a tab is scoped to its own
                        // library for good, so it gets no Library pill and its
                        // label stays true.
                        LibraryItemsView(initialQuery: LibraryQuery(library: library))
                    }
                }
            }
        }
    #else
        /// Every library behind one tab (#138): a grid of library cards, each
        /// pushing that library's grid onto this tab's own stack.
        ///
        /// The `Library` destination is registered here rather than in
        /// `navigationRoot`, which every tab shares: nothing on tvOS pushes a
        /// library, so scoping it to this stack keeps that platform's
        /// navigation literally untouched by this change.
        ///
        /// `libraryOptions` *is* passed, unlike a tvOS library tab: the
        /// destination arrives with a back button rather than a tab label, so
        /// there is no label for the Library pill to contradict, and the
        /// viewer can re-scope without walking back to the grid.
        private var librariesTab: some TabContent<AppTab> {
            Tab("Libraries", systemImage: "square.stack.3d.down.forward.fill", value: AppTab.libraries) {
                navigationRoot(for: .libraries) {
                    LibrariesGridView(libraries: connectionViewModel.libraries)
                        .navigationDestination(for: Library.self) { library in
                            LibraryItemsView(
                                initialQuery: LibraryQuery(library: library),
                                libraryOptions: connectionViewModel.libraries,
                            )
                        }
                }
            }
        }
    #endif

    /// `role: .search` declares that this tab owns searching. On its own it did
    /// not clear the collision in #148 — the tvOS `sidebarAdaptable` collapsed
    /// pill still drew over the search field on device, even though the
    /// simulator reported it fixed — so `SearchView` carries the inset that
    /// actually does. The role stays because it is a true declaration that was
    /// simply missing (`git log -S"role: .search"` finds no prior removal), and
    /// it costs nothing. Not `#if`-guarded: semantically true on visionOS too,
    /// where a device check found no regression.
    private var searchTab: some TabContent<AppTab> {
        Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
            navigationRoot(for: .search) {
                SearchView()
            }
            // The inset goes on the NavigationStack, not inside SearchView.
            // `.searchable` draws its field in the stack's bar, above the
            // content — padding applied within `SearchView` moved the results
            // and left the field exactly where it was, still under the pill.
            //
            // `.padding`, not `.safeAreaPadding`: the latter insets against an
            // existing safe area, and a stack that already fills its tab has
            // none to bite on, so it was a no-op at any value. Plain padding
            // shrinks the proposed frame and the bar lays out inside it.
            #if os(tvOS)
            .padding(.top, Self.searchHeadroom)
            // The padding opens a strip above the search field that belongs to
            // no view — `SearchView`'s own background is inside it. Paint it
            // here or the system backdrop shows through.
            .background(themeManager.currentTheme.background)
            #endif
        }
    }

    #if os(tvOS)
        /// Headroom above the Search tab's stack so the `sidebarAdaptable`
        /// collapsed pill, which draws over content at the top-leading corner,
        /// clears the system search field (#148).
        ///
        /// Tuned on an Apple TV, and only there: the tvOS simulator renders
        /// this layout differently and reported the collision fixed when it was
        /// not. Bisect against hardware if it ever needs revisiting — nothing
        /// in this repo can measure it.
        private static let searchHeadroom: CGFloat = SpacingTokens.sm

        /// How long to let the outgoing stack's pop land before committing a
        /// tab switch. Named so anything that must outlast the settle derives
        /// from it rather than restating the number (#236 § 4).
        ///
        /// Tuned on an Apple TV. Bisect against hardware if it needs
        /// revisiting; nothing in this repo can measure it.
        static let popSettle: Duration = .milliseconds(350)
    #endif

    private var settingsTab: some TabContent<AppTab> {
        Tab("Settings", systemImage: "gear", value: AppTab.settings) {
            navigationRoot(for: .settings) {
                SettingsView()
            }
        }
    }

    /// The per-tab `NavigationStack`, bound to this tab's path, with the
    /// media-detail, person-detail, and genre-filtered-library destinations
    /// registered at the root so every shelf/grid card (and details pushed from
    /// other details) resolves through it.
    private func navigationRoot(
        for tab: AppTab,
        @ViewBuilder content: () -> some View,
    ) -> some View {
        NavigationStack(path: path(for: tab)) {
            content()
                .navigationDestination(for: MediaItem.self) { item in
                    MediaDetailView(item: item)
                }
                .navigationDestination(for: CastMember.self) { member in
                    PersonDetailView(member: member)
                }
                .navigationDestination(for: GenreFilter.self) { filter in
                    // Seeded to the shelf's library but not bound to it: this
                    // grid has no tab label to contradict, so the viewer can
                    // widen it to every library from the Library pill.
                    LibraryItemsView(
                        initialQuery: LibraryQuery(library: filter.library, genres: [filter.genre]),
                        libraryOptions: connectionViewModel.libraries,
                    )
                }
        }
    }
}

// MARK: - Root Navigation Actions

/// Switches the root TabView to the Settings tab. Views that need to
/// point a stranded user at Settings (e.g. Home's empty states, where
/// nothing else on screen is focusable and the collapsed sidebar can't
/// take focus — #69) call this instead of reaching into tab state.
struct OpenSettingsAction: Equatable {
    fileprivate let handler: () -> Void

    func callAsFunction() {
        handler()
    }

    static func == (_: Self, _: Self) -> Bool {
        true
    }
}

/// Pushes a media item's detail page onto the current tab's stack.
/// Provided by `RootView` (owner of the per-tab paths) for actions that
/// can't be a `NavigationLink` — e.g. "View Details" in a shelf card's
/// long-press menu, where selecting the card itself plays instead.
struct PushMediaDetailAction: Equatable {
    fileprivate let handler: (MediaItem) -> Void

    func callAsFunction(_ item: MediaItem) {
        handler(item)
    }

    static func == (_: Self, _: Self) -> Bool {
        true
    }
}

extension EnvironmentValues {
    /// Wrapped in an `Equatable` action rather than stored as a bare closure:
    /// `@Entry` compares the old and new value to decide whether readers need
    /// re-evaluating, and a closure isn't comparable, so every root update
    /// would invalidate every reader. Both actions read `RootView`'s live
    /// `@State` when called, so an instance from a later body pass behaves
    /// identically to the one it replaces — all instances are interchangeable
    /// and `==` is unconditionally true. The `Optional` still distinguishes
    /// "provided" from "not provided", which `HomePlaceholders` relies on to
    /// decide whether to offer the button at all.
    @Entry var openSettings: OpenSettingsAction? = nil

    /// See `openSettings` for why this is an action type and not a closure.
    @Entry var pushMediaDetail: PushMediaDetailAction? = nil
}

// MARK: - Tab

extension RootView {
    /// Top-level navigation destinations.
    ///
    /// Both library cases are declared on both platforms even though each is
    /// selectable on only one — tvOS gets the dynamic per-library tabs,
    /// visionOS the single collapsed one (#138). A case that platform never
    /// selects is inert, and that costs far less than an `#if` at every switch
    /// over this enum.
    enum AppTab: Hashable {
        case home
        /// tvOS: one tab per server library, keyed by the library's id.
        case library(String)
        /// visionOS: every library behind one grid.
        case libraries
        case search
        case settings
    }
}

// MARK: - Preview

#Preview {
    RootView()
}

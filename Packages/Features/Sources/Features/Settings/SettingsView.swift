import DesignSystem
import JellyfinKit
import SwiftUI

/// Settings screen for app configuration
public struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ServerConnectionViewModel.self) private var connection
    @Environment(HomePreferences.self) private var homePreferences
    @Environment(PlaybackPreferences.self) private var playbackPreferences

    public init() {}

    /// Pushable Settings screens; value-based so RootView's pre-switch
    /// pop-to-root covers Settings' stack too.
    enum Destination: Hashable {
        case serverConnection
        case addProfile
        case themeSelection
        case streamingQuality
    }

    /// No NavigationStack here: RootView owns each tab's stack (with a path
    /// binding) so it can pop to root before a tab switch — see RootView's
    /// `tabSelection` for the tvOS bug this works around.
    public var body: some View {
        // @Bindable so the Toggles can bind into the @Observable preferences.
        @Bindable var homePreferences = homePreferences
        @Bindable var playbackPreferences = playbackPreferences

        List {
            pageTitle(LocalizedStringResource("settings.title", bundle: #bundle, comment: "Big title at the top of the Settings screen."))

            // Server Section
            Section {
                NavigationLink(value: Destination.serverConnection) {
                    settingsRow(
                        icon: "server.rack",
                        title: LocalizedStringResource("settings.row.server", bundle: #bundle, comment: "Settings row that opens the server and profiles page."),
                        subtitle: serverSubtitle,
                    )
                }
            } header: {
                sectionHeader(LocalizedStringResource("settings.section.connection", bundle: #bundle, comment: "Settings section heading over the server row."))
            }

            // Appearance Section
            Section {
                NavigationLink(value: Destination.themeSelection) {
                    settingsRow(
                        icon: "paintpalette.fill",
                        title: LocalizedStringResource("settings.row.theme", bundle: #bundle, comment: "Settings row that opens the theme picker."),
                        subtitle: themeManager.currentTheme.name,
                    )
                }
            } header: {
                sectionHeader(LocalizedStringResource("settings.section.appearance", bundle: #bundle, comment: "Settings section heading over the theme row."))
            }

            // Home Section
            Section {
                Toggle(isOn: $homePreferences.mergesContinueWatching) {
                    settingsRow(
                        icon: "popcorn.fill",
                        title: LocalizedStringResource("settings.row.combinedContinueWatching", bundle: #bundle, comment: "Settings switch that merges the Next Up shelf into Continue Watching."),
                        subtitle: LocalizedStringResource("settings.row.combinedContinueWatching.subtitle", bundle: #bundle, comment: "Explains the Combined Continue Watching switch."),
                    )
                }
                .tint(theme.accent)

                Toggle(isOn: $homePreferences.showsDiscoveryShelves) {
                    settingsRow(
                        icon: "sparkles",
                        title: LocalizedStringResource("settings.row.picksForYou", bundle: #bundle, comment: "Settings switch that shows Home shelves picked from the viewer’s history."),
                        subtitle: LocalizedStringResource("settings.row.picksForYou.subtitle", bundle: #bundle, comment: "Explains the Picks for you switch."),
                    )
                }
                .tint(theme.accent)
            } header: {
                sectionHeader(LocalizedStringResource("settings.section.home", bundle: #bundle, comment: "Settings section heading over the Home screen options."))
            }

            // Playback Section
            Section {
                NavigationLink(value: Destination.streamingQuality) {
                    settingsRow(
                        icon: "gauge.with.dots.needle.67percent",
                        title: LocalizedStringResource("settings.row.streamingQuality", bundle: #bundle, comment: "Settings row that opens the streaming quality picker."),
                        subtitle: playbackPreferences.streamingQuality.displayName,
                    )
                }

                Toggle(isOn: $playbackPreferences.asksVersionBeforePlaying) {
                    settingsRow(
                        icon: "square.stack.3d.up.fill",
                        title: LocalizedStringResource("settings.row.askWhichVersion", bundle: #bundle, comment: "Settings switch that asks which version to play when a title has several."),
                        subtitle: LocalizedStringResource("settings.row.askWhichVersion.subtitle", bundle: #bundle, comment: "Explains the Ask Which Version switch."),
                    )
                }
                .tint(theme.accent)
            } header: {
                sectionHeader(LocalizedStringResource("settings.section.playback", bundle: #bundle, comment: "Settings section heading over the playback options."))
            }

            // About Section — informational only, deliberately unfocusable: no
            // icon or row platter, so it reads as a footer rather than a
            // selectable row (#157). A real About page is #29's call.
            Section {
                Text(versionText)
                    .jsStyle(.caption)
                    .foregroundStyle(theme.secondary)
                    .listRowBackground(Color.clear)
            } header: {
                sectionHeader(LocalizedStringResource("settings.section.about", bundle: #bundle, comment: "Settings section heading over the app version."))
            }
        }
        // tvOS List is already transparent (and lacks this modifier); visionOS
        // needs the system list background hidden first.
        #if os(visionOS)
        .scrollContentBackground(.hidden)
        .navigationTitle(LocalizedStringResource("settings.navigationTitle", bundle: #bundle, comment: "Title of the settings screen."))
        #endif
        .background(theme.background)
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .serverConnection:
                ServerConnectionView()
            case .addProfile:
                AddProfileView()
            case .themeSelection:
                themeSelectionView
            case .streamingQuality:
                streamingQualityView
            }
        }
    }

    private var versionText: LocalizedStringResource {
        let version = AppVersion.text() ?? String(localized: LocalizedStringResource("settings.about.unknownVersion", bundle: #bundle, comment: "Stands in for the app version when it can’t be read."))
        return LocalizedStringResource("settings.about.version \(version)", bundle: #bundle, comment: "The app version in Settings, such as “Version 0.13.0 (42)”. %@ is the version.")
    }

    private var serverSubtitle: LocalizedStringResource {
        switch connection.state {
        case .connected:
            if let user = connection.connectedUser {
                let name = user.name
                return LocalizedStringResource("settings.server.connectedAs \(name)", bundle: #bundle, comment: "Server row subtitle once signed in. %@ is the user’s name from the server.")
            }
            return LocalizedStringResource("settings.server.connected", bundle: #bundle, comment: "Server row subtitle once signed in, when the user’s name isn’t known yet.")
        case .connecting, .authenticating:
            return LocalizedStringResource("settings.server.connecting", bundle: #bundle, comment: "Server row subtitle while signing in.")
        case .disconnected:
            return LocalizedStringResource("settings.server.notConnected", bundle: #bundle, comment: "Server row subtitle when signed out.")
        }
    }

    private func pageTitle(_ title: LocalizedStringResource) -> some View {
        SettingsPageTitle(Text(title))
    }

    private func sectionHeader(_ title: LocalizedStringResource) -> some View {
        SettingsSectionHeader(Text(title))
    }

    private func settingsRow(icon: String, title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
        SettingsRowLabel(icon: icon, title: title, subtitle: subtitle)
    }

    private var themeSelectionView: some View {
        List {
            pageTitle(LocalizedStringResource("settings.theme.title", bundle: #bundle, comment: "Big title at the top of the theme picker."))

            ForEach(themeManager.availableThemes, id: \.self) { (themeId: ThemeIdentifier) in
                Button {
                    themeManager.switchTheme(to: themeId)
                } label: {
                    SelectionRowLabel(
                        name: themeId.displayName,
                        description: themeDescription(for: themeId),
                        isSelected: themeManager.currentThemeId == themeId,
                    )
                }
                .buttonStyle(.plain)
            }
        }
        #if os(visionOS)
        .scrollContentBackground(.hidden)
        .navigationTitle(LocalizedStringResource("settings.theme.navigationTitle", bundle: #bundle, comment: "Title of the screen for choosing a visual theme."))
        #endif
        .background(theme.background)
    }

    /// The streaming ceiling picker (#168). Deliberately the same shape as
    /// the theme picker above — a list of plain buttons with a checkmark —
    /// rather than a `Picker`: that shape is the one whose focus and themed
    /// platter behavior is proven on device here.
    private var streamingQualityView: some View {
        List {
            pageTitle(LocalizedStringResource("settings.streamingQuality.title", bundle: #bundle, comment: "Big title at the top of the streaming quality picker."))

            ForEach(StreamingQualityTier.allCases, id: \.self) { tier in
                Button {
                    playbackPreferences.streamingQuality = tier
                } label: {
                    SelectionRowLabel(
                        name: tier.displayName,
                        description: tier.summary,
                        isSelected: playbackPreferences.streamingQuality == tier,
                    )
                }
                .buttonStyle(.plain)
            }
        }
        #if os(visionOS)
        .scrollContentBackground(.hidden)
        .navigationTitle(LocalizedStringResource("settings.streamingQuality.navigationTitle", bundle: #bundle, comment: "Title of the screen for choosing a streaming bitrate limit."))
        #endif
        .background(theme.background)
    }

    private func themeDescription(for themeId: ThemeIdentifier) -> LocalizedStringResource {
        switch themeId {
        case .standard:
            LocalizedStringResource("settings.theme.standard.summary", bundle: #bundle, comment: "One-line summary of the Standard theme in the theme picker.")
        case .horror:
            LocalizedStringResource("settings.theme.horror.summary", bundle: #bundle, comment: "One-line summary of the Horror theme in the theme picker.")
        case .action:
            LocalizedStringResource("settings.theme.action.summary", bundle: #bundle, comment: "One-line summary of the Action theme in the theme picker.")
        case .videoStore:
            LocalizedStringResource("settings.theme.videoStore.summary", bundle: #bundle, comment: "One-line summary of the Video Store theme in the theme picker.")
        case .sciFi:
            LocalizedStringResource("settings.theme.sciFi.summary", bundle: #bundle, comment: "One-line summary of the Sci-Fi theme in the theme picker.")
        }
    }
}

/// Row label for the main Settings list. Focused rows sit on the light system
/// platter, so the text swaps to the on-platter tokens (see ``SelectionRowLabel``).
private struct SettingsRowLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let icon: String
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    var body: some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .jsStyle(.title)
                .foregroundStyle(theme.accent)
                .frame(width: SpacingTokens.lg)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(title)
                    .jsStyle(.body)
                    .foregroundStyle(isFocused ? theme.onPlatter : theme.primary)

                Text(subtitle)
                    .jsStyle(.caption)
                    .foregroundStyle(isFocused ? theme.onPlatterSecondary : theme.secondary)
            }
        }
        .padding(.vertical, SpacingTokens.xs)
        .animation(theme.animation, value: isFocused)
    }
}

/// Label for a row in a selection sub-list (themes, streaming quality). When
/// the `.plain` button gains focus, tvOS lifts it onto a light system platter
/// — the theme's content colors disappear against it, so the text swaps to
/// the on-platter tokens. `\.isFocused` only resolves inside the focusable's
/// subtree, hence a dedicated view (same pattern as ``OverviewLabel``).
private struct SelectionRowLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let name: LocalizedStringResource
    let description: LocalizedStringResource
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(name)
                    .jsStyle(.body)
                    .foregroundStyle(isFocused ? theme.onPlatter : theme.primary)

                Text(description)
                    .jsStyle(.caption)
                    .foregroundStyle(isFocused ? theme.onPlatterSecondary : theme.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.vertical, SpacingTokens.xs)
        .animation(theme.animation, value: isFocused)
    }
}

/// How the streaming tiers read to a viewer. The values live in JellyfinKit
/// (they are what the server is asked for); the words are the app's, so the
/// client package carries no UI strings. Number-only names ("40 Mbps")
/// still go through the catalog: the unit and its spacing are the locale's.
private extension StreamingQualityTier {
    /// The engine's declared ceiling in Mbps, for the Maximum row, so the
    /// label and the declaration cannot drift apart.
    static var declaredCeilingMbps: Int {
        AVFoundationPlayerEngine.capabilities.maxStreamingBitrate / 1_000_000
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .maximum: LocalizedStringResource("settings.streamingQuality.maximum", bundle: #bundle, comment: "Streaming quality option with no limit below the player’s own ceiling.")
        case .mbps40: LocalizedStringResource("settings.streamingQuality.mbps \(40)", bundle: #bundle, comment: "A streaming bitrate limit in megabits per second. %lld is the number, such as 40.")
        case .mbps20: LocalizedStringResource("settings.streamingQuality.mbps \(20)", bundle: #bundle, comment: "A streaming bitrate limit in megabits per second. %lld is the number, such as 40.")
        case .mbps8: LocalizedStringResource("settings.streamingQuality.mbps \(8)", bundle: #bundle, comment: "A streaming bitrate limit in megabits per second. %lld is the number, such as 40.")
        case .mbps4: LocalizedStringResource("settings.streamingQuality.mbps \(4)", bundle: #bundle, comment: "A streaming bitrate limit in megabits per second. %lld is the number, such as 40.")
        case .mbps2: LocalizedStringResource("settings.streamingQuality.mbps \(2)", bundle: #bundle, comment: "A streaming bitrate limit in megabits per second. %lld is the number, such as 40.")
        }
    }

    /// Deliberately no resolution promises: the request carries a bitrate
    /// ceiling and nothing else, so what the server sends back at a given
    /// tier depends on the source and its own encoder settings. These say
    /// which connection a tier is for, which is the part that is true.
    var summary: LocalizedStringResource {
        switch self {
        case .maximum: LocalizedStringResource("settings.streamingQuality.maximum.summary \(Self.declaredCeilingMbps)", bundle: #bundle, comment: "Explains the Maximum streaming quality. %lld is the player’s ceiling in megabits per second, such as 120.")
        case .mbps40: LocalizedStringResource("settings.streamingQuality.mbps40.summary", bundle: #bundle, comment: "Explains the 40 Mbps streaming limit.")
        case .mbps20: LocalizedStringResource("settings.streamingQuality.mbps20.summary", bundle: #bundle, comment: "Explains the 20 Mbps streaming limit.")
        case .mbps8: LocalizedStringResource("settings.streamingQuality.mbps8.summary", bundle: #bundle, comment: "Explains the 8 Mbps streaming limit.")
        case .mbps4: LocalizedStringResource("settings.streamingQuality.mbps4.summary", bundle: #bundle, comment: "Explains the 4 Mbps streaming limit.")
        case .mbps2: LocalizedStringResource("settings.streamingQuality.mbps2.summary", bundle: #bundle, comment: "Explains the 2 Mbps streaming limit.")
        }
    }
}

/// Page title in the theme's display face, the loudest typographic
/// difference between themes. tvOS can't restyle `navigationTitle`, so
/// Settings pages put the title in their content instead.
struct SettingsPageTitle: View {
    @Environment(\.theme) private var theme
    private let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .jsStyle(.display)
            .foregroundStyle(theme.primary)
            .padding(.bottom, SpacingTokens.md)
            .listRowBackground(Color.clear)
    }
}

/// Section heading on Settings pages, in the theme's caption face.
struct SettingsSectionHeader: View {
    @Environment(\.theme) private var theme
    private let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .jsStyle(.caption)
            .foregroundStyle(theme.secondary)
    }
}

#if DEBUG
    // Picking a theme in any of these previews restyles the canvas without
    // touching the simulator's persisted selection — the preview manager
    // never saves.
    #Preview("Standard", traits: .featuresEnvironment) {
        NavigationStack {
            SettingsView()
        }
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        NavigationStack {
            SettingsView()
        }
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        NavigationStack {
            SettingsView()
        }
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        NavigationStack {
            SettingsView()
        }
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        NavigationStack {
            SettingsView()
        }
    }
#endif

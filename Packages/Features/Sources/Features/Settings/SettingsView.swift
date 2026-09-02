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
            pageTitle("Settings")

            // Server Section
            Section {
                NavigationLink(value: Destination.serverConnection) {
                    settingsRow(
                        icon: "server.rack",
                        title: "Server",
                        subtitle: serverSubtitle,
                    )
                }
            } header: {
                sectionHeader("Connection")
            }

            // Appearance Section
            Section {
                NavigationLink(value: Destination.themeSelection) {
                    settingsRow(
                        icon: "paintpalette.fill",
                        title: "Theme",
                        subtitle: themeManager.currentTheme.name,
                    )
                }
            } header: {
                sectionHeader("Appearance")
            }

            // Home Section
            Section {
                Toggle(isOn: $homePreferences.mergesContinueWatching) {
                    settingsRow(
                        icon: "popcorn.fill",
                        title: "Combined Continue Watching",
                        subtitle: "Fold Next Up into one shelf, sorted by recent activity",
                    )
                }
                .tint(theme.accent)
            } header: {
                sectionHeader("Home")
            }

            // Playback Section
            Section {
                NavigationLink(value: Destination.streamingQuality) {
                    settingsRow(
                        icon: "gauge.with.dots.needle.67percent",
                        title: "Streaming Quality",
                        subtitle: playbackPreferences.streamingQuality.displayName,
                    )
                }

                Toggle(isOn: $playbackPreferences.asksVersionBeforePlaying) {
                    settingsRow(
                        icon: "square.stack.3d.up.fill",
                        title: "Ask Which Version",
                        subtitle: "When a title has several versions, ask before playing instead of a long-press menu",
                    )
                }
                .tint(theme.accent)
            } header: {
                sectionHeader("Playback")
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
                sectionHeader("About")
            }
        }
        // tvOS List is already transparent (and lacks this modifier); visionOS
        // needs the system list background hidden first.
        #if os(visionOS)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        #endif
        .background(theme.background)
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .serverConnection:
                ServerConnectionView()
            case .themeSelection:
                themeSelectionView
            case .streamingQuality:
                streamingQualityView
            }
        }
    }

    /// Read from the bundle so the displayed version can't drift from
    /// `MARKETING_VERSION` (#157). Local builds carry the default build number
    /// `1` (CI overrides it per release, see docs/RELEASING.md), which says
    /// nothing, so it's omitted.
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let build = info?["CFBundleVersion"] as? String, build != "1" else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
    }

    private var serverSubtitle: String {
        switch connection.state {
        case .connected:
            if let user = connection.connectedUser {
                return "Connected as \(user.name)"
            }
            return "Connected"
        case .connecting, .authenticating:
            return "Connecting..."
        case .disconnected:
            return "Not connected"
        }
    }

    /// Page title rendered in the theme's display face — the loudest
    /// typographic differentiator between themes. tvOS can't restyle
    /// `navigationTitle`, so the title lives in the list instead.
    private func pageTitle(_ title: String) -> some View {
        Text(title)
            .jsStyle(.display)
            .foregroundStyle(theme.primary)
            .padding(.bottom, SpacingTokens.md)
            .listRowBackground(Color.clear)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .jsStyle(.caption)
            .foregroundStyle(theme.secondary)
    }

    private func settingsRow(icon: String, title: String, subtitle: String) -> some View {
        SettingsRowLabel(icon: icon, title: title, subtitle: subtitle)
    }

    private var themeSelectionView: some View {
        List {
            pageTitle("Theme")

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
        .navigationTitle("Theme")
        #endif
        .background(theme.background)
    }

    /// The streaming ceiling picker (#168). Deliberately the same shape as
    /// the theme picker above — a list of plain buttons with a checkmark —
    /// rather than a `Picker`: that shape is the one whose focus and themed
    /// platter behavior is proven on device here.
    private var streamingQualityView: some View {
        List {
            pageTitle("Streaming Quality")

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
        .navigationTitle("Streaming Quality")
        #endif
        .background(theme.background)
    }

    private func themeDescription(for themeId: ThemeIdentifier) -> String {
        switch themeId {
        case .standard:
            "Elegant, timeless baseline"
        case .horror:
            "Atmospheric dread, visceral intensity"
        case .action:
            "Kinetic energy, technological precision"
        case .videoStore:
            "90s nostalgia, Friday night vibes"
        case .sciFi:
            "Deep-space greens, engineered precision"
        }
    }
}

/// Row label for the main Settings list. Focused rows sit on the light system
/// platter, so the text swaps to the on-platter tokens (see ``SelectionRowLabel``).
private struct SettingsRowLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .jsStyle(.title)
                .foregroundStyle(theme.accent)
                .frame(width: 32)

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

    let name: String
    let description: String
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
/// client package carries no UI strings.
private extension StreamingQualityTier {
    /// The engine's declared ceiling, formatted for the Maximum row, so the
    /// label and the declaration cannot drift apart.
    static var declaredCeilingLabel: String {
        "\(AVFoundationPlayerEngine.capabilities.maxStreamingBitrate / 1_000_000) Mbps"
    }

    var displayName: String {
        switch self {
        case .maximum: "Maximum"
        case .mbps40: "40 Mbps"
        case .mbps20: "20 Mbps"
        case .mbps8: "8 Mbps"
        case .mbps4: "4 Mbps"
        case .mbps2: "2 Mbps"
        }
    }

    /// Deliberately no resolution promises: the request carries a bitrate
    /// ceiling and nothing else, so what the server sends back at a given
    /// tier depends on the source and its own encoder settings. These say
    /// which connection a tier is for, which is the part that is true.
    var summary: String {
        switch self {
        case .maximum: "Up to \(Self.declaredCeilingLabel), best quality on a fast network"
        case .mbps40: "Plenty of room for large files on a strong home network"
        case .mbps20: "A comfortable ceiling for most home networks"
        case .mbps8: "For a shared or busy connection"
        case .mbps4: "For a slow or metered connection"
        case .mbps2: "For a connection that stalls at anything higher"
        }
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

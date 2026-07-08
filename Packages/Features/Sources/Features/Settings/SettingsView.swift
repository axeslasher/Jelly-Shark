import SwiftUI
import DesignSystem

/// Settings screen for app configuration
public struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(ServerConnectionViewModel.self) private var connection

    public init() {}

    /// Pushable Settings screens; value-based so RootView's pre-switch
    /// pop-to-root covers Settings' stack too.
    enum Destination: Hashable {
        case serverConnection
        case themeSelection
    }

    // No NavigationStack here: RootView owns each tab's stack (with a path
    // binding) so it can pop to root before a tab switch — see RootView's
    // `tabSelection` for the tvOS bug this works around.
    public var body: some View {
        List {
            pageTitle("Settings")

            // Server Section
            Section {
                NavigationLink(value: Destination.serverConnection) {
                    settingsRow(
                        icon: "server.rack",
                        title: "Server",
                        subtitle: serverSubtitle
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
                        subtitle: themeManager.currentTheme.name
                    )
                }
            } header: {
                sectionHeader("Appearance")
            }

            // Playback Section
            Section {
                settingsRow(
                    icon: "play.circle.fill",
                    title: "Playback",
                    subtitle: "Quality, subtitles, audio"
                )
            } header: {
                sectionHeader("Playback")
            }

            // About Section
            Section {
                settingsRow(
                    icon: "info.circle.fill",
                    title: "About",
                    subtitle: "Version 0.0.1"
                )
            } header: {
                sectionHeader("About")
            }
        }
        // tvOS List is already transparent (and lacks this modifier); other
        // platforms need the system list background hidden first.
        #if !os(tvOS)
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
            }
        }
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
            .font(theme.jsDisplay)
            .foregroundStyle(theme.primary)
            .padding(.bottom, SpacingTokens.md)
            .listRowBackground(Color.clear)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(theme.jsCaption)
            .foregroundStyle(theme.secondary)
    }

    private func settingsRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .font(theme.jsTitle)
                .foregroundStyle(theme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(title)
                    .font(theme.jsBody)
                    .foregroundStyle(theme.primary)

                Text(subtitle)
                    .font(theme.jsCaption)
                    .foregroundStyle(theme.secondary)
            }
        }
        .padding(.vertical, SpacingTokens.xs)
    }

    private var themeSelectionView: some View {
        List {
            pageTitle("Theme")

            ForEach(themeManager.availableThemes, id: \.self) { (themeId: ThemeIdentifier) in
                Button {
                    themeManager.switchTheme(to: themeId)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(themeId.displayName)
                                .font(theme.jsBody)
                                .foregroundStyle(theme.primary)

                            Text(themeDescription(for: themeId))
                                .font(theme.jsCaption)
                                .foregroundStyle(theme.secondary)
                        }

                        Spacer()

                        if themeManager.currentThemeId == themeId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.vertical, SpacingTokens.xs)
                }
                .buttonStyle(.plain)
            }
        }
        #if !os(tvOS)
        .scrollContentBackground(.hidden)
        .navigationTitle("Theme")
        #endif
        .background(theme.background)
    }

    private func themeDescription(for themeId: ThemeIdentifier) -> String {
        switch themeId {
        case .standard:
            return "Elegant, timeless baseline"
        case .horror:
            return "Atmospheric dread, visceral intensity"
        case .action:
            return "Kinetic energy, technological precision"
        case .videoStore:
            return "90s nostalgia, Friday night vibes"
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .withThemeEnvironment()
    .environment(AppSession())
    .environment(ServerConnectionViewModel())
}

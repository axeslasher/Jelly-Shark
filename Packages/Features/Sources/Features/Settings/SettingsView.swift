import SwiftUI
import DesignSystem

/// Settings screen for app configuration
public struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeManager.self) private var themeManager

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // Server Section
                Section {
                    NavigationLink {
                        ServerConnectionView()
                    } label: {
                        settingsRow(
                            icon: "server.rack",
                            title: "Server",
                            subtitle: "Not connected"
                        )
                    }
                } header: {
                    Text("Connection")
                }

                // Appearance Section
                Section {
                    NavigationLink {
                        themeSelectionView
                    } label: {
                        settingsRow(
                            icon: "paintpalette.fill",
                            title: "Theme",
                            subtitle: themeManager.currentTheme.name
                        )
                    }
                } header: {
                    Text("Appearance")
                }

                // Playback Section
                Section {
                    settingsRow(
                        icon: "play.circle.fill",
                        title: "Playback",
                        subtitle: "Quality, subtitles, audio"
                    )
                } header: {
                    Text("Playback")
                }

                // About Section
                Section {
                    settingsRow(
                        icon: "info.circle.fill",
                        title: "About",
                        subtitle: "Version 0.0.1"
                    )
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func settingsRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .font(.jsTitle)
                .foregroundStyle(theme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(title)
                    .font(.jsBody)
                    .foregroundStyle(theme.primary)

                Text(subtitle)
                    .font(.jsCaption)
                    .foregroundStyle(theme.secondary)
            }
        }
        .padding(.vertical, SpacingTokens.xs)
    }

    private var themeSelectionView: some View {
        List {
            ForEach(themeManager.availableThemes, id: \.self) { (themeId: ThemeIdentifier) in
                Button {
                    themeManager.switchTheme(to: themeId)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(themeId.displayName)
                                .font(.jsBody)
                                .foregroundStyle(theme.primary)

                            Text(themeDescription(for: themeId))
                                .font(.jsCaption)
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
        .navigationTitle("Theme")
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
    SettingsView()
        .withThemeEnvironment()
}

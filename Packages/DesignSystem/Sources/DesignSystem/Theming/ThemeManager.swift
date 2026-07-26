// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI

/// Manages the current theme and handles theme switching
@MainActor
@Observable
public final class ThemeManager {
    // MARK: - Singleton

    /// Shared theme manager instance
    public static let shared = ThemeManager()

    // MARK: - Properties

    /// The currently active theme
    public private(set) var currentTheme: any Theme

    /// The current theme identifier
    public var currentThemeId: ThemeIdentifier {
        didSet {
            currentTheme = theme(for: currentThemeId)
            saveThemePreference()
        }
    }

    /// All available themes
    public let availableThemes: [ThemeIdentifier] = ThemeIdentifier.allCases

    // MARK: - Private

    private let userDefaultsKey = "selectedTheme"

    // MARK: - Initialization

    private init() {
        // Load saved theme preference or default to standard
        let savedId = UserDefaults.standard.string(forKey: userDefaultsKey)
            .flatMap { ThemeIdentifier(rawValue: $0) } ?? .standard

        self.currentThemeId = savedId
        self.currentTheme = ThemeManager.createTheme(for: savedId)

        // Register the bundled fonts once so `theme.js*` styles resolve to the
        // right typeface from first render.
        DesignSystemFonts.registerAll()
    }

    // MARK: - Public Methods

    /// Switch to a different theme with animation
    /// - Parameter themeId: The theme to switch to
    public func switchTheme(to themeId: ThemeIdentifier) {
        withAnimation(.easeInOut(duration: MotionTokens.durationThemeTransition)) {
            currentThemeId = themeId
        }
    }

    /// Get the theme instance for a given identifier
    /// - Parameter id: The theme identifier
    /// - Returns: The theme instance
    public func theme(for id: ThemeIdentifier) -> any Theme {
        ThemeManager.createTheme(for: id)
    }

    // MARK: - Private Methods

    private static func createTheme(for id: ThemeIdentifier) -> any Theme {
        switch id {
        case .standard:
            StandardTheme()
        case .horror:
            HorrorTheme()
        case .action:
            ActionTheme()
        case .videoStore:
            VideoStoreTheme()
        case .sciFi:
            SciFiTheme()
        }
    }

    private func saveThemePreference() {
        UserDefaults.standard.set(currentThemeId.rawValue, forKey: userDefaultsKey)
    }
}

// MARK: - Environment Key

/// Stable default instance for the `\.theme` entry — `@Entry` requires a
/// default expression that returns the same value on every read.
private let defaultTheme: any Theme = StandardTheme()

public extension EnvironmentValues {
    /// The current theme
    @Entry var theme: any Theme = defaultTheme
}

// MARK: - View Extension

public extension View {
    /// Apply the current theme to the view hierarchy
    func withThemeEnvironment(_ manager: ThemeManager = .shared) -> some View {
        self
            .environment(\.theme, manager.currentTheme)
            .environment(manager)
    }
}

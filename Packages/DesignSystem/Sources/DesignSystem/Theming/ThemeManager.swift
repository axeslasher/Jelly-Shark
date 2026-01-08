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
            return StandardTheme()
        case .horror:
            return StandardTheme() // TODO: Replace with HorrorTheme
        case .action:
            return StandardTheme() // TODO: Replace with ActionTheme
        case .videoStore:
            return StandardTheme() // TODO: Replace with VideoStoreTheme
        }
    }

    private func saveThemePreference() {
        UserDefaults.standard.set(currentThemeId.rawValue, forKey: userDefaultsKey)
    }
}

// MARK: - Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: any Theme = StandardTheme()
}

private struct ThemeManagerKey: EnvironmentKey {
    @MainActor static let defaultValue: ThemeManager = .shared
}

public extension EnvironmentValues {
    /// The current theme
    var theme: any Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    /// The theme manager
    var themeManager: ThemeManager {
        get { self[ThemeManagerKey.self] }
        set { self[ThemeManagerKey.self] = newValue }
    }
}

// MARK: - View Extension

public extension View {
    /// Apply the current theme to the view hierarchy
    func withThemeEnvironment(_ manager: ThemeManager = .shared) -> some View {
        self
            .environment(\.theme, manager.currentTheme)
            .environment(\.themeManager, manager)
    }
}

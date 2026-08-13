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

    private static let userDefaultsKey = "selectedTheme"

    /// When false (preview instances), theme changes never touch UserDefaults.
    private let persistsSelection: Bool

    // MARK: - Initialization

    private init(themeId: ThemeIdentifier, persistsSelection: Bool) {
        self.persistsSelection = persistsSelection
        self.currentThemeId = themeId
        self.currentTheme = ThemeManager.createTheme(for: themeId)

        // Register the bundled fonts once so `theme.js*` styles resolve to the
        // right typeface from first render.
        DesignSystemFonts.registerAll()
    }

    private convenience init() {
        // Load saved theme preference or default to standard
        let savedId = UserDefaults.standard.string(forKey: ThemeManager.userDefaultsKey)
            .flatMap { ThemeIdentifier(rawValue: $0) } ?? .standard

        self.init(themeId: savedId, persistsSelection: true)
    }

    /// A standalone manager pinned to `id` that never writes UserDefaults.
    /// For `#Preview` bodies and tests; the app always uses `.shared`.
    public static func preview(_ id: ThemeIdentifier = .standard) -> ThemeManager {
        ThemeManager(themeId: id, persistsSelection: false)
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
        guard persistsSelection else { return }
        UserDefaults.standard.set(currentThemeId.rawValue, forKey: ThemeManager.userDefaultsKey)
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

    /// Preview companion to `withThemeEnvironment`: pins a non-persisting
    /// preview theme and paints its `background` token behind the content —
    /// the same ground real screens paint — so component previews render on
    /// the theme's canvas instead of the simulator default. Like
    /// `ThemeManager.preview`, deliberately not `#if DEBUG`-gated so
    /// literal-only previews can stay unwrapped.
    func previewCanvas(_ id: ThemeIdentifier = .standard) -> some View {
        let manager = ThemeManager.preview(id)
        return frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(manager.currentTheme.background.ignoresSafeArea())
            .withThemeEnvironment(manager)
    }
}

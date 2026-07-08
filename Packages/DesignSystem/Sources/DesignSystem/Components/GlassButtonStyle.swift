import SwiftUI

public extension View {
    /// The Liquid Glass button treatment used by prominent actions. `.glass` is
    /// unavailable on macOS 15, which the package builds for only to run tests;
    /// there it falls back to `.bordered`.
    ///
    /// - Parameter tint: Tints the glass — pass the theme's `focusFill` so the
    ///   focus platter takes on the theme's hue. `nil` keeps the system look.
    @ViewBuilder
    func glassButtonStyle(tint: Color? = nil) -> some View {
        #if os(macOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.glass(.clear.tint(tint)))
        #endif
    }
}

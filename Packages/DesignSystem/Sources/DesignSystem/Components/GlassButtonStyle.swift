import SwiftUI

public extension View {
    /// The Liquid Glass button treatment used by prominent actions. `.glass` is
    /// unavailable on macOS 15, which the package builds for only to run tests;
    /// there it falls back to `.bordered`.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.glass(.clear))
        #endif
    }
}

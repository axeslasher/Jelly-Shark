@testable import Features
import Testing

@Suite("VersionPicker")
struct VersionSelectionTests {
    @Test("Single-version items get no picker in either mode")
    func singleVersionNever() {
        #expect(VersionPicker.presentation(sourceCount: 0, asksBeforePlaying: false) == .none)
        #expect(VersionPicker.presentation(sourceCount: 1, asksBeforePlaying: false) == .none)
        #expect(VersionPicker.presentation(sourceCount: 1, asksBeforePlaying: true) == .none)
    }

    @Test("Long-press mode offers the menu")
    func longPressMode() {
        #expect(VersionPicker.presentation(sourceCount: 2, asksBeforePlaying: false) == .menu)
        #expect(VersionPicker.presentation(sourceCount: 8, asksBeforePlaying: false) == .menu)
    }

    @Test("Ask mode alerts up to the cap, then falls back to the menu")
    func askModeCapped() {
        #expect(VersionPicker.presentation(sourceCount: 2, asksBeforePlaying: true) == .alert)
        #expect(
            VersionPicker.presentation(
                sourceCount: VersionPicker.alertVersionCap,
                asksBeforePlaying: true,
            ) == .alert,
        )
        #expect(
            VersionPicker.presentation(
                sourceCount: VersionPicker.alertVersionCap + 1,
                asksBeforePlaying: true,
            ) == .menu,
        )
    }
}

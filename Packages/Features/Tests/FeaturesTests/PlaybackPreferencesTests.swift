@testable import Features
import Foundation
import Testing

@Suite("PlaybackPreferences")
@MainActor
struct PlaybackPreferencesTests {
    /// A scratch defaults suite per test, so nothing leaks into the standard
    /// domain (or between tests).
    private func makeDefaults() -> UserDefaults {
        let suiteName = "PlaybackPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Long-press is the default: nothing persisted means don't ask")
    func defaultsToLongPress() {
        #expect(PlaybackPreferences(defaults: makeDefaults()).asksVersionBeforePlaying == false)
    }

    @Test("The choice persists across instances (relaunches)")
    func persistsAcrossInstances() {
        let defaults = makeDefaults()

        let first = PlaybackPreferences(defaults: defaults)
        first.asksVersionBeforePlaying = true
        #expect(PlaybackPreferences(defaults: defaults).asksVersionBeforePlaying)

        let second = PlaybackPreferences(defaults: defaults)
        second.asksVersionBeforePlaying = false
        #expect(PlaybackPreferences(defaults: defaults).asksVersionBeforePlaying == false)
    }
}

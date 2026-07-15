@testable import Features
import Foundation
import Testing

@Suite("HomePreferences")
@MainActor
struct HomePreferencesTests {
    /// A scratch defaults suite per test, so nothing leaks into the standard
    /// domain (or between tests).
    private func makeDefaults() -> UserDefaults {
        let suiteName = "HomePreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Merging is the default when nothing is persisted")
    func defaultsToMerged() {
        #expect(HomePreferences(defaults: makeDefaults()).mergesContinueWatching)
    }

    @Test("The choice persists across instances (relaunches)")
    func persistsAcrossInstances() {
        let defaults = makeDefaults()

        let first = HomePreferences(defaults: defaults)
        first.mergesContinueWatching = false
        #expect(HomePreferences(defaults: defaults).mergesContinueWatching == false)

        let second = HomePreferences(defaults: defaults)
        second.mergesContinueWatching = true
        #expect(HomePreferences(defaults: defaults).mergesContinueWatching)
    }
}

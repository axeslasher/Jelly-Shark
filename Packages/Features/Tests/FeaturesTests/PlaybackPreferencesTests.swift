@testable import Features
import Foundation
import JellyfinKit
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

    @Test("Maximum is the default: nothing persisted means no user cap")
    func defaultsToMaximumQuality() {
        // The default has to be the uncapped tier, or an untouched install
        // would start negotiating differently than it did before #168 —
        // including losing direct play for files it is offered for today.
        let preferences = PlaybackPreferences(defaults: makeDefaults())
        #expect(preferences.streamingQuality == .maximum)
        #expect(preferences.streamingQuality.bitsPerSecond == nil)
    }

    @Test("The streaming ceiling persists across instances (relaunches)")
    func streamingQualityPersistsAcrossInstances() {
        let defaults = makeDefaults()

        let first = PlaybackPreferences(defaults: defaults)
        first.streamingQuality = .mbps2
        #expect(PlaybackPreferences(defaults: defaults).streamingQuality == .mbps2)

        let second = PlaybackPreferences(defaults: defaults)
        second.streamingQuality = .mbps20
        #expect(PlaybackPreferences(defaults: defaults).streamingQuality == .mbps20)
    }

    @Test("An explicit Maximum is stored, not just implied by absence")
    func explicitMaximumIsPersisted() {
        // Picking Maximum after another tier has to write a value, not clear
        // one: absence and an explicit choice read the same today, but only
        // a stored value can survive a future change of default.
        let defaults = makeDefaults()
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.streamingQuality = .mbps8
        preferences.streamingQuality = .maximum

        #expect(defaults.object(forKey: "streamingQualityBitrate") as? Int == 0)
        #expect(PlaybackPreferences(defaults: defaults).streamingQuality == .maximum)
    }

    @Test("A stored ceiling this build no longer names falls back to Maximum")
    func unknownStoredTierFallsBack() {
        let defaults = makeDefaults()
        // Spelled out rather than read from the type: the persisted key and
        // its bits-per-second encoding are the compatibility contract with
        // builds either side of this one, so a rename should fail here.
        defaults.set(3_000_000, forKey: "streamingQualityBitrate")

        #expect(PlaybackPreferences(defaults: defaults).streamingQuality == .maximum)
    }
}

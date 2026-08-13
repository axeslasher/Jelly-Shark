@testable import DesignSystem
import Foundation
import Testing

@Suite("Preview support")
struct PreviewSupportTests {
    /// The regression that proves `.preview(_:)` is safe in `#Preview` bodies:
    /// constructing and mutating a preview manager must leave the app's
    /// persisted theme selection untouched.
    @MainActor
    @Test("Preview managers never persist theme selection")
    func previewManagerDoesNotPersist() {
        let key = "selectedTheme"
        let before = UserDefaults.standard.string(forKey: key)

        let manager = ThemeManager.preview(.horror)
        #expect(manager.currentThemeId == .horror)
        #expect(manager.currentTheme is HorrorTheme)

        manager.currentThemeId = .sciFi
        #expect(manager.currentTheme is SciFiTheme)

        #expect(UserDefaults.standard.string(forKey: key) == before)
    }

    @MainActor
    @Test("Preview managers default to the standard theme")
    func previewManagerDefaultsToStandard() {
        let manager = ThemeManager.preview()
        #expect(manager.currentThemeId == .standard)
        #expect(manager.currentTheme is StandardTheme)
    }

    /// The PreviewData hashes are generated offline; this is what makes them
    /// safe to commit — every one must decode, and the deliberately-broken one
    /// must not.
    @Test("Every PreviewData blurhash decodes")
    func previewDataHashesDecode() {
        for hash in PreviewData.posterHashes + PreviewData.backdropHashes {
            #expect(BlurHash.decode(hash, width: 8, height: 8) != nil, "undecodable hash: \(hash)")
        }
        #expect(BlurHash.decode(PreviewData.invalidHash, width: 8, height: 8) == nil)
    }

    @Test("PreviewData titles pair with poster hashes")
    func previewDataTitleCountMatchesPosters() {
        #expect(PreviewData.movieTitles.count == PreviewData.posterHashes.count)
    }
}

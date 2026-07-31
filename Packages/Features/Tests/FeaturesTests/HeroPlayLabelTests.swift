@testable import Features
import Testing

@Suite("HeroPlayLabel")
struct HeroPlayLabelTests {
    // The in-flight-toggle cases (watched must read Replay immediately,
    // unwatched must drop to Play and never a stale Resume) moved with the
    // override mechanism into the user-state overlay: `UserStateStore`
    // clears the resolved resume position alongside a pending played
    // toggle, and the MediaDetail overlay tests pin that end to end.

    @Test("Fresh, unwatched item reads Play with the play glyph")
    func freshItemReadsPlay() {
        let label = HeroPlayLabel.label(played: false, hasProgress: false)
        #expect(label.title == "Play")
        #expect(label.systemImage == "play.fill")
    }

    @Test("In-progress item reads Resume with the play glyph")
    func inProgressReadsResume() {
        let label = HeroPlayLabel.label(played: false, hasProgress: true)
        #expect(label.title == "Resume")
        #expect(label.systemImage == "play.fill")
    }

    @Test("Fully-watched item reads Replay with the circular-arrow glyph")
    func watchedReadsReplay() {
        let label = HeroPlayLabel.label(played: true, hasProgress: false)
        #expect(label.title == "Replay")
        #expect(label.systemImage == "arrow.counterclockwise")
    }
}

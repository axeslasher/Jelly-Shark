@testable import Features
import Testing

@Suite("HeroPlayLabel")
struct HeroPlayLabelTests {
    // MARK: - No pending override (reflects stored user data)

    @Test("Fresh, unwatched item reads Play with the play glyph")
    func freshItemReadsPlay() {
        let label = HeroPlayLabel.label(playedOverride: nil, played: false, hasProgress: false)
        #expect(label.title == "Play")
        #expect(label.systemImage == "play.fill")
    }

    @Test("In-progress item reads Resume with the play glyph")
    func inProgressReadsResume() {
        let label = HeroPlayLabel.label(playedOverride: nil, played: false, hasProgress: true)
        #expect(label.title == "Resume")
        #expect(label.systemImage == "play.fill")
    }

    @Test("Fully-watched item reads Replay with the circular-arrow glyph")
    func watchedReadsReplay() {
        let label = HeroPlayLabel.label(playedOverride: nil, played: true, hasProgress: false)
        #expect(label.title == "Replay")
        #expect(label.systemImage == "arrow.counterclockwise")
    }

    // MARK: - Pending optimistic override (supersedes stored progress)

    @Test("Optimistic mark-watched reads Replay immediately, ignoring stale progress")
    func optimisticWatchedReadsReplay() {
        // The stored item still carries a resume position (hasProgress true),
        // but marking watched clears it server-side — the label must not lag as
        // "Resume".
        let label = HeroPlayLabel.label(playedOverride: true, played: false, hasProgress: true)
        #expect(label.title == "Replay")
        #expect(label.systemImage == "arrow.counterclockwise")
    }

    @Test("Optimistic mark-unwatched drops to Play, not a stale Resume")
    func optimisticUnwatchedReadsPlay() {
        // Marking unwatched also clears the resume position, so a previously
        // in-progress item must read "Play", never "Resume".
        let label = HeroPlayLabel.label(playedOverride: false, played: true, hasProgress: true)
        #expect(label.title == "Play")
        #expect(label.systemImage == "play.fill")
    }
}

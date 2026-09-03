import Foundation
@testable import JellyfinKit
import Testing

@Suite("MediaItem progress for poster cards")
struct MediaItemProgressTests {
    /// Series shape: progress comes from the episode counts, never a
    /// playback position.
    private func series(episodes: Int?, unplayed: Int?) -> MediaItem {
        MediaItem(
            id: "series-1",
            name: "Series",
            type: .series,
            recursiveItemCount: episodes,
            userData: UserData(unplayedItemCount: unplayed),
        )
    }

    /// Movie shape: progress comes from the resume position against runtime.
    private func movie(positionTicks: Int64?, runtimeTicks: Int64?) -> MediaItem {
        MediaItem(
            id: "movie-1",
            name: "Movie",
            type: .movie,
            runTimeTicks: runtimeTicks,
            userData: UserData(playbackPositionTicks: positionTicks),
        )
    }

    @Test("Part-watched series reports the watched fraction")
    func partWatchedSeries() {
        #expect(series(episodes: 10, unplayed: 4).watchedFraction == 0.6)
    }

    @Test("A series with no episodes watched has no fraction")
    func untouchedSeries() {
        #expect(series(episodes: 10, unplayed: 10).watchedFraction == nil)
    }

    @Test("A fully watched series has no fraction")
    func finishedSeries() {
        #expect(series(episodes: 10, unplayed: 0).watchedFraction == nil)
    }

    @Test("Missing counts yield no fraction")
    func missingCounts() {
        #expect(series(episodes: nil, unplayed: 4).watchedFraction == nil)
        #expect(series(episodes: 10, unplayed: nil).watchedFraction == nil)
        #expect(series(episodes: 0, unplayed: 0).watchedFraction == nil)
    }

    @Test("Poster progress prefers a container's fraction")
    func cardProgressForContainer() {
        #expect(series(episodes: 4, unplayed: 1).cardProgress == 0.75)
    }

    @Test("Poster progress uses a leaf item's resume position")
    func cardProgressForLeaf() {
        #expect(movie(positionTicks: 250, runtimeTicks: 1000).cardProgress == 0.25)
    }

    @Test("Poster progress ignores a leaf at either end of the range")
    func cardProgressClampsLeaf() {
        // A finished item reports position == runtime; an unstarted one
        // reports zero. Neither should draw a bar.
        #expect(movie(positionTicks: 1000, runtimeTicks: 1000).cardProgress == nil)
        #expect(movie(positionTicks: 0, runtimeTicks: 1000).cardProgress == nil)
        #expect(movie(positionTicks: nil, runtimeTicks: 1000).cardProgress == nil)
    }
}

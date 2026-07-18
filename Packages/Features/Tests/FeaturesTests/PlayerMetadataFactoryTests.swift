import AVFoundation
@testable import Features
import Foundation
import JellyfinKit
import Testing

@MainActor
@Suite("PlayerMetadataFactory")
struct PlayerMetadataFactoryTests {
    private func chapter(
        name: String = "Chapter",
        startSeconds: Double,
        imageIndex: Int = 0,
        imageTag: String? = nil,
    ) -> Chapter {
        Chapter(
            name: name,
            startTicks: Int64(startSeconds * 10_000_000),
            imageIndex: imageIndex,
            imageTag: imageTag,
        )
    }

    private func value(of identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) -> Any? {
        items.first { $0.identifier == identifier }?.value
    }

    // MARK: - Navigation markers

    #if os(tvOS)
        @Test("Markers carry titles and contiguous time ranges ending at the duration")
        func markerTimeRanges() throws {
            let group = try #require(PlayerMetadataFactory.navigationMarkerGroup(
                chapters: [
                    chapter(name: "One", startSeconds: 0),
                    chapter(name: "Two", startSeconds: 300),
                    chapter(name: "Three", startSeconds: 900),
                ],
                durationSeconds: 1200,
            ))

            #expect(group.title == nil)
            let markers = try #require(group.timedNavigationMarkers)
            #expect(markers.count == 3)

            let titles = markers.map { $0.items.first { $0.identifier == .commonIdentifierTitle }?.value as? String }
            #expect(titles == ["One", "Two", "Three"])

            #expect(markers[0].timeRange.start.seconds == 0)
            #expect(markers[0].timeRange.end.seconds == 300)
            #expect(markers[1].timeRange.end.seconds == 900)
            #expect(markers[2].timeRange.end.seconds == 1200)
        }

        @Test("Chapters at or past the duration are dropped; none left means nil")
        func overDurationChapters() {
            let group = PlayerMetadataFactory.navigationMarkerGroup(
                chapters: [
                    chapter(name: "In range", startSeconds: 10),
                    chapter(name: "At end", startSeconds: 600),
                    chapter(name: "Past end", startSeconds: 900),
                ],
                durationSeconds: 600,
            )
            #expect(group?.timedNavigationMarkers?.count == 1)

            #expect(PlayerMetadataFactory.navigationMarkerGroup(
                chapters: [chapter(startSeconds: 600)],
                durationSeconds: 600,
            ) == nil)
            #expect(PlayerMetadataFactory.navigationMarkerGroup(chapters: [], durationSeconds: 600) == nil)
            #expect(PlayerMetadataFactory.navigationMarkerGroup(
                chapters: [chapter(startSeconds: 0)],
                durationSeconds: 0,
            ) == nil)
        }

        @Test("Artwork data lands on the marker with the matching image index")
        func artworkPlacement() throws {
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
            let group = try #require(PlayerMetadataFactory.navigationMarkerGroup(
                chapters: [
                    chapter(name: "One", startSeconds: 0, imageIndex: 0),
                    chapter(name: "Two", startSeconds: 300, imageIndex: 2),
                ],
                durationSeconds: 600,
                artwork: [2: jpeg],
            ))

            let markers = try #require(group.timedNavigationMarkers)
            #expect(value(of: .commonIdentifierArtwork, in: markers[0].items) == nil)
            #expect(value(of: .commonIdentifierArtwork, in: markers[1].items) as? Data == jpeg)
        }
    #endif

    // MARK: - External metadata

    @Test("Movie metadata carries title, tagline subtitle, and detail fields")
    func movieMetadata() {
        let item = MediaItem(
            id: "movie-1",
            name: "The Movie",
            type: .movie,
            overview: "A test film.",
            officialRating: "PG-13",
            tagline: "Nothing is real",
            genres: ["Horror", "Comedy"],
        )

        let items = PlayerMetadataFactory.externalMetadata(for: item)

        #expect(value(of: .commonIdentifierTitle, in: items) as? String == "The Movie")
        #expect(value(of: .iTunesMetadataTrackSubTitle, in: items) as? String == "Nothing is real")
        #expect(value(of: .commonIdentifierDescription, in: items) as? String == "A test film.")
        #expect(value(of: .quickTimeMetadataGenre, in: items) as? String == "Horror, Comedy")
        #expect(value(of: .iTunesMetadataContentRating, in: items) as? String == "PG-13")
        #expect(value(of: .commonIdentifierArtwork, in: items) == nil)
    }

    @Test("Episode metadata uses the series and episode code as the subtitle")
    func episodeMetadata() {
        let item = MediaItem(
            id: "ep-1",
            name: "The One Where It Works",
            type: .episode,
            seriesName: "The Show",
            indexNumber: 5,
            parentIndexNumber: 2,
        )

        let items = PlayerMetadataFactory.externalMetadata(for: item)
        #expect(value(of: .iTunesMetadataTrackSubTitle, in: items) as? String == "The Show · S2E5")
    }

    @Test("Artwork data is included only when provided")
    func artworkInclusion() {
        let item = MediaItem(id: "movie-1", name: "The Movie", type: .movie)
        let poster = Data([0xFF, 0xD8, 0xFF, 0xD9])

        let withArt = PlayerMetadataFactory.externalMetadata(for: item, artworkData: poster)
        #expect(value(of: .commonIdentifierArtwork, in: withArt) as? Data == poster)

        let withoutArt = PlayerMetadataFactory.externalMetadata(for: item)
        #expect(value(of: .commonIdentifierArtwork, in: withoutArt) == nil)
    }
}

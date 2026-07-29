import AVFoundation
@testable import Features
import JellyfinKit
import Testing

/// The AVFoundation half of the seam (#85): the small set of facts the old
/// PlaybackViewModel tests asserted against a real player, now confined to
/// the one suite that constructs one. Marker/metadata *content* is covered
/// by PlayerMetadataFactoryTests; this covers that the engine attaches it.
@Suite("AVFoundationPlayerEngine")
@MainActor
struct AVFoundationPlayerEngineTests {
    private func makeMetadata(
        chapters: [Chapter] = [],
        durationSeconds: Double? = nil,
    ) -> PlayerSessionMetadata {
        PlayerSessionMetadata(
            item: MediaItem(id: "movie-1", name: "Test Movie", type: .movie),
            chapters: chapters,
            durationSeconds: durationSeconds,
        )
    }

    private let streamURL = URL(string: "https://example.com/Videos/movie-1/stream")!

    @Test("load() builds a player on the URL with automatic selection off")
    func loadBuildsPlayer() throws {
        let engine = AVFoundationPlayerEngine()

        engine.load(url: streamURL, metadata: makeMetadata(), loadsLegibleOptions: false)

        #expect(engine.isLoaded)
        let player = try #require(engine.player)
        #expect((player.currentItem?.asset as? AVURLAsset)?.url == streamURL)
        // The master playlist marks every text rendition AUTOSELECT=YES;
        // left on, AVPlayer would enable subtitles behind the app's back
        #expect(player.appliesMediaSelectionCriteriaAutomatically == false)
        #expect(engine.transportStatus == .paused)
        engine.teardown()
    }

    @Test("load() attaches external metadata and chapter markers")
    func loadAttachesMetadata() throws {
        let engine = AVFoundationPlayerEngine()
        let chapters = [
            Chapter(name: "One", startTicks: 0, imageIndex: 0),
            Chapter(name: "Two", startTicks: 36_000_000_000, imageIndex: 1),
        ]

        engine.load(
            url: streamURL,
            metadata: makeMetadata(chapters: chapters, durationSeconds: 7200),
            loadsLegibleOptions: false,
        )

        let playerItem = try #require(engine.player?.currentItem)
        #expect(!playerItem.externalMetadata.isEmpty)
        #if os(tvOS)
            let group = try #require(playerItem.navigationMarkerGroups.first)
            #expect(group.title == nil)
            #expect(group.timedNavigationMarkers?.count == 2)
        #endif
        engine.teardown()
    }

    @Test("A missing duration skips markers but not metadata")
    func missingDurationSkipsMarkers() throws {
        let engine = AVFoundationPlayerEngine()
        let chapters = [Chapter(name: "One", startTicks: 0, imageIndex: 0)]

        engine.load(
            url: streamURL,
            metadata: makeMetadata(chapters: chapters, durationSeconds: nil),
            loadsLegibleOptions: false,
        )

        let playerItem = try #require(engine.player?.currentItem)
        #expect(!playerItem.externalMetadata.isEmpty)
        #if os(tvOS)
            #expect(playerItem.navigationMarkerGroups.isEmpty)
        #endif
        engine.teardown()
    }

    @Test("Enrichment re-applies metadata with the fetched artwork")
    func enrichmentReappliesMetadata() throws {
        let engine = AVFoundationPlayerEngine()
        engine.load(url: streamURL, metadata: makeMetadata(), loadsLegibleOptions: false)
        let playerItem = try #require(engine.player?.currentItem)
        let before = playerItem.externalMetadata.count

        engine.applyEnrichedMetadata(chapterArtwork: [:], posterData: Data([0xFF, 0xD8]))

        #expect(playerItem.externalMetadata.count == before + 1)
        engine.teardown()
    }

    @Test("Enrichment with nothing fetched leaves the item untouched")
    func emptyEnrichmentIsANoOp() throws {
        let engine = AVFoundationPlayerEngine()
        engine.load(url: streamURL, metadata: makeMetadata(), loadsLegibleOptions: false)
        let playerItem = try #require(engine.player?.currentItem)
        let before = playerItem.externalMetadata.count

        engine.applyEnrichedMetadata(chapterArtwork: [:], posterData: nil)

        #expect(playerItem.externalMetadata.count == before)
        engine.teardown()
    }

    @Test("A second load swaps the player instance")
    func secondLoadSwapsPlayer() throws {
        let engine = AVFoundationPlayerEngine()
        engine.load(url: streamURL, metadata: makeMetadata(), loadsLegibleOptions: false)
        let first = try #require(engine.player)

        engine.load(
            url: URL(string: "https://example.com/Videos/movie-1/master.m3u8")!,
            metadata: makeMetadata(),
            loadsLegibleOptions: true,
        )

        #expect(engine.player !== first)
        engine.teardown()
    }

    @Test("teardown() drops the player and resets every read surface")
    func teardownResetsState() {
        let engine = AVFoundationPlayerEngine()
        engine.load(url: streamURL, metadata: makeMetadata(), loadsLegibleOptions: false)

        engine.teardown()

        #expect(!engine.isLoaded)
        #expect(engine.player == nil)
        #expect(engine.currentTimeSeconds == nil)
        #expect(engine.currentErrorDescription == nil)
        #expect(engine.transportStatus == .paused)
        #expect(engine.audibleOptions.isEmpty)
        #expect(engine.legibleOptions.isEmpty)
        #expect(engine.selectedAudiblePosition == nil)
        #expect(engine.selectedLegiblePosition == nil)
        #expect(engine.deliveryProgress() == DeliveryProgress())
    }
}

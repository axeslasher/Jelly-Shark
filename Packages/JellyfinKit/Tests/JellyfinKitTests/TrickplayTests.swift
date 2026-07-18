import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

/// The SDK ships its own `JellyfinAPI.TrickplayInfo` entity; in this file the
/// domain type is always the one under test
private typealias TrickplayInfo = JellyfinKit.TrickplayInfo

@Suite("TrickplayResolver")
struct TrickplayResolverTests {
    /// 320px-wide thumbnails on a 4×3 grid (12 per sheet), one every 10s,
    /// 30 thumbnails total — so sheets 0 and 1 are full and sheet 2 holds six
    private let info = TrickplayInfo(
        widthKey: 320,
        thumbnailWidth: 320,
        thumbnailHeight: 180,
        columns: 4,
        rows: 3,
        intervalMilliseconds: 10000,
        thumbnailCount: 30,
    )

    @Test("Position zero resolves to the first thumbnail")
    func startOfContent() {
        let location = TrickplayResolver.location(atSeconds: 0, info: info)
        #expect(location.tileIndex == 0)
        #expect(location.cropRect == CGRect(x: 0, y: 0, width: 320, height: 180))
    }

    @Test("Interior position lands on the right sheet, row, and column")
    func interiorPosition() {
        // 145s / 10s = thumbnail 14 → sheet 1 (14 / 12), index 2 within the
        // sheet → row 0, column 2
        let location = TrickplayResolver.location(atSeconds: 145, info: info)
        #expect(location.tileIndex == 1)
        #expect(location.cropRect == CGRect(x: 640, y: 0, width: 320, height: 180))
    }

    @Test("Row advances every `columns` thumbnails")
    func rowAdvance() {
        // 50s / 10s = thumbnail 5 → sheet 0, row 1, column 1
        let location = TrickplayResolver.location(atSeconds: 50, info: info)
        #expect(location.tileIndex == 0)
        #expect(location.cropRect == CGRect(x: 320, y: 180, width: 320, height: 180))
    }

    @Test("A sheet boundary starts the next sheet at its top-left cell")
    func sheetBoundary() {
        // Thumbnail 12 is the first of sheet 1
        let location = TrickplayResolver.location(atSeconds: 120, info: info)
        #expect(location.tileIndex == 1)
        #expect(location.cropRect == CGRect(x: 0, y: 0, width: 320, height: 180))
    }

    @Test("Positions past the end clamp to the last real thumbnail")
    func clampsPastEnd() {
        // Thumbnail 29 is the last: sheet 2, index 5 within it → row 1, column 1
        let expected = TrickplayResolver.location(atSeconds: 290, info: info)
        #expect(TrickplayResolver.location(atSeconds: 9999, info: info) == expected)
        #expect(expected.tileIndex == 2)
        #expect(expected.cropRect == CGRect(x: 320, y: 180, width: 320, height: 180))
    }

    @Test("Negative and non-finite positions clamp to the first thumbnail")
    func clampsInvalidPositions() {
        let first = TrickplayResolver.location(atSeconds: 0, info: info)
        #expect(TrickplayResolver.location(atSeconds: -5, info: info) == first)
        #expect(TrickplayResolver.location(atSeconds: .infinity, info: info) == first)
        #expect(TrickplayResolver.location(atSeconds: .nan, info: info) == first)
    }

    @Test("Single-row and single-column grids resolve without crossing axes")
    func degenerateGrids() {
        let singleRow = TrickplayInfo(
            widthKey: 320, thumbnailWidth: 100, thumbnailHeight: 50,
            columns: 5, rows: 1, intervalMilliseconds: 1000, thumbnailCount: 20,
        )
        // Thumbnail 7 → sheet 1, column 2, always row 0
        let rowLocation = TrickplayResolver.location(atSeconds: 7, info: singleRow)
        #expect(rowLocation.tileIndex == 1)
        #expect(rowLocation.cropRect == CGRect(x: 200, y: 0, width: 100, height: 50))

        let singleColumn = TrickplayInfo(
            widthKey: 320, thumbnailWidth: 100, thumbnailHeight: 50,
            columns: 1, rows: 5, intervalMilliseconds: 1000, thumbnailCount: 20,
        )
        // Thumbnail 7 → sheet 1, row 2, always column 0
        let columnLocation = TrickplayResolver.location(atSeconds: 7, info: singleColumn)
        #expect(columnLocation.tileIndex == 1)
        #expect(columnLocation.cropRect == CGRect(x: 0, y: 100, width: 100, height: 50))
    }
}

@Suite("Trickplay adapters")
struct TrickplayAdapterTests {
    private func dto(
        interval: Int? = 10000,
        width: Int? = 320,
        height: Int? = 180,
        tileWidth: Int? = 4,
        tileHeight: Int? = 3,
        thumbnailCount: Int? = 30,
    ) -> JellyfinAPI.TrickplayInfoDto {
        JellyfinAPI.TrickplayInfoDto(
            height: height,
            interval: interval,
            thumbnailCount: thumbnailCount,
            tileHeight: tileHeight,
            tileWidth: tileWidth,
            width: width,
        )
    }

    @Test("DTO fields map onto the descriptive names")
    func fieldMapping() throws {
        let info = try #require(TrickplayInfo(widthKey: 320, from: dto()))
        #expect(info.widthKey == 320)
        #expect(info.thumbnailWidth == 320)
        #expect(info.thumbnailHeight == 180)
        // The server's TileWidth/TileHeight count thumbnails per row/column
        #expect(info.columns == 4)
        #expect(info.rows == 3)
        #expect(info.intervalMilliseconds == 10000)
        #expect(info.thumbnailCount == 30)
    }

    @Test("Missing or non-positive geometry drops the entry")
    func rejectsMalformedEntries() {
        #expect(TrickplayInfo(widthKey: 320, from: dto(interval: nil)) == nil)
        #expect(TrickplayInfo(widthKey: 320, from: dto(interval: 0)) == nil)
        #expect(TrickplayInfo(widthKey: 320, from: dto(width: -1)) == nil)
        #expect(TrickplayInfo(widthKey: 320, from: dto(height: nil)) == nil)
        #expect(TrickplayInfo(widthKey: 320, from: dto(tileWidth: 0)) == nil)
        #expect(TrickplayInfo(widthKey: 320, from: dto(tileHeight: nil)) == nil)
        #expect(TrickplayInfo(widthKey: 320, from: dto(thumbnailCount: 0)) == nil)
    }

    @Test("Manifest maps sources and sorts resolutions by width")
    func manifestMapping() throws {
        let manifest = try #require(TrickplayManifest(from: [
            "source-1": [
                "480": dto(width: 480),
                "320": dto(),
            ],
        ]))

        let infos = try #require(manifest.sources["source-1"])
        #expect(infos.map(\.widthKey) == [320, 480])
    }

    @Test("Unparseable width keys and empty sources are dropped")
    func dropsUnusableEntries() {
        // The only resolution has a bad key → the source vanishes → nil manifest
        #expect(TrickplayManifest(from: ["source-1": ["huge": dto()]]) == nil)
        // A malformed sibling drops silently, the good one survives
        let manifest = TrickplayManifest(from: [
            "source-1": ["320": dto(), "480": dto(interval: 0)],
        ])
        #expect(manifest?.sources["source-1"]?.map(\.widthKey) == [320])
    }

    @Test("Empty dictionary means no manifest")
    func emptyManifest() {
        #expect(TrickplayManifest(from: [:]) == nil)
    }
}

@Suite("TrickplayManifest lookup")
struct TrickplayManifestLookupTests {
    private func info(width: Int) -> TrickplayInfo {
        TrickplayInfo(
            widthKey: width, thumbnailWidth: width, thumbnailHeight: width * 9 / 16,
            columns: 4, rows: 3, intervalMilliseconds: 10000, thumbnailCount: 30,
        )
    }

    @Test("Exact media source id wins, nearest width is chosen")
    func exactSourceNearestWidth() {
        let manifest = TrickplayManifest(sources: [
            "source-1": [info(width: 320), info(width: 480)],
            "source-2": [info(width: 1280)],
        ])

        #expect(manifest.info(forMediaSourceId: "source-1")?.widthKey == 320)
        #expect(manifest.info(forMediaSourceId: "source-1", preferredWidth: 500)?.widthKey == 480)
        #expect(manifest.info(forMediaSourceId: "source-2")?.widthKey == 1280)
    }

    @Test("Width ties break toward the smaller resolution")
    func widthTieBreak() {
        let manifest = TrickplayManifest(sources: ["source-1": [info(width: 300), info(width: 340)]])
        #expect(manifest.info(forMediaSourceId: "source-1")?.widthKey == 300)
    }

    @Test("A single-source manifest matches even when the id differs")
    func singleSourceFallback() {
        let manifest = TrickplayManifest(sources: ["other-id": [info(width: 320)]])
        #expect(manifest.info(forMediaSourceId: "source-1")?.widthKey == 320)
    }

    @Test("An unknown id in a multi-source manifest returns nil")
    func unknownSourceInMultiSourceManifest() {
        let manifest = TrickplayManifest(sources: [
            "source-1": [info(width: 320)],
            "source-2": [info(width: 320)],
        ])
        #expect(manifest.info(forMediaSourceId: "source-3") == nil)
    }
}

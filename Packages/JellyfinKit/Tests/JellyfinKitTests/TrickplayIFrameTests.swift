import AVFoundation
import Foundation
@testable import JellyfinKit
import Testing

/// The SDK ships its own `JellyfinAPI.TrickplayInfo`; here the domain type
/// is always the one under test
private typealias TrickplayInfo = JellyfinKit.TrickplayInfo

private let sampleInfo = TrickplayInfo(
    widthKey: 320,
    thumbnailWidth: 320,
    thumbnailHeight: 180,
    columns: 10,
    rows: 10,
    intervalMilliseconds: 10000,
    thumbnailCount: 60,
    bandwidth: 4170,
)

// MARK: - Muxer

@Suite("TrickplayIFrameMuxer")
struct TrickplayIFrameMuxerTests {
    /// Parse the top-level MP4 boxes of a chunk of data
    private func boxTypes(of data: Data) -> [String] {
        var types: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size = data.subdata(in: offset ..< offset + 4).reduce(0) { ($0 << 8) | Int($1) }
            let type = String(decoding: data.subdata(in: offset + 4 ..< offset + 8), as: UTF8.self)
            types.append(type)
            guard size >= 8 else { break }
            offset += size
        }
        return types
    }

    @Test("Initialization segment is ftyp followed by moov")
    func initSegmentStructure() {
        let segment = TrickplayIFrameMuxer.initializationSegment(
            thumbnailWidth: 320,
            thumbnailHeight: 180,
            durationMilliseconds: 600_000,
        )
        #expect(boxTypes(of: segment) == ["ftyp", "moov"])
        // The sample entry advertises the mjpg image-sequence codec
        #expect(segment.range(of: Data("mjpg".utf8)) != nil)
    }

    @Test("Media segment is moof plus mdat carrying the JPEG verbatim")
    func mediaSegmentStructure() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let segment = TrickplayIFrameMuxer.mediaSegment(
            index: 3,
            durationMilliseconds: 10000,
            jpegData: jpeg,
        )
        #expect(boxTypes(of: segment) == ["moof", "mdat"])
        #expect(segment.suffix(jpeg.count) == jpeg)
    }

    @Test("Fragment data offset points at the mdat payload")
    func dataOffsetTargetsPayload() throws {
        let jpeg = Data(repeating: 0xAB, count: 100)
        let segment = TrickplayIFrameMuxer.mediaSegment(
            index: 0,
            durationMilliseconds: 10000,
            jpegData: jpeg,
        )

        // trun data offset sits 8 bytes after the trun box header + fullbox
        // header + sample count; find trun and read the offset
        let trunRange = try #require(segment.range(of: Data("trun".utf8)))
        let offsetStart = segment.index(trunRange.upperBound, offsetBy: 8)
        let dataOffset = segment.subdata(in: offsetStart ..< segment.index(offsetStart, offsetBy: 4))
            .reduce(0) { ($0 << 8) | Int($1) }

        // The byte at moof start + dataOffset must be the first JPEG byte
        #expect(segment[segment.startIndex + dataOffset] == 0xAB)
    }

    @Test("AVFoundation parses the muxed sequence as playable mjpg video")
    func avFoundationRoundTrip() async throws {
        // A minimal but valid JPEG: encode a 320x180 image via ImageIO
        let jpeg = try #require(Self.solidJPEG(width: 320, height: 180))

        var movie = TrickplayIFrameMuxer.initializationSegment(
            thumbnailWidth: 320,
            thumbnailHeight: 180,
            durationMilliseconds: 20000,
        )
        movie += TrickplayIFrameMuxer.mediaSegment(index: 0, durationMilliseconds: 10000, jpegData: jpeg)
        movie += TrickplayIFrameMuxer.mediaSegment(index: 1, durationMilliseconds: 10000, jpegData: jpeg)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trickplay-muxer-test-\(UUID().uuidString).mp4")
        try movie.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let asset = AVURLAsset(url: fileURL)
        #expect(try await asset.load(.isPlayable))
        let tracks = try await asset.load(.tracks)
        #expect(tracks.count == 1)
        let size = try #require(try await tracks.first?.load(.naturalSize))
        #expect(Int(size.width) == 320)
        #expect(Int(size.height) == 180)
    }

    private static func solidJPEG(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue,
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

// MARK: - Playlists

@Suite("TrickplayHLSPlaylist")
struct TrickplayHLSPlaylistTests {
    private let masterURL = URL(string: "https://example.com/jellyfin/Videos/item-1/master.m3u8?api_key=tok")!

    /// Rewrite and unwrap, for the cases that supply a genuine master playlist
    private func rewrite(_ master: String, info: TrickplayInfo?) throws -> String {
        try #require(TrickplayHLSPlaylist.rewriteMaster(
            master,
            originalURL: masterURL,
            iframePlaylistURI: "custom://iframe.m3u8",
            info: info,
        )).playlist
    }

    @Test("Plain URI lines are resolved against the master URL")
    func absolutizesURILines() throws {
        let rewritten = try rewrite(
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1.42401F",RESOLUTION=1280x720
            main.m3u8?api_key=tok&VideoCodec=h264
            """,
            info: sampleInfo,
        )
        #expect(rewritten.contains("\nhttps://example.com/jellyfin/Videos/item-1/main.m3u8?api_key=tok&VideoCodec=h264\n"))
    }

    @Test("URI attributes in tag lines are resolved in place")
    func absolutizesURIAttributes() throws {
        let rewritten = try rewrite(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs.m3u8?index=3"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            main.m3u8
            """,
            info: sampleInfo,
        )
        #expect(rewritten.contains("URI=\"https://example.com/jellyfin/Videos/item-1/subs.m3u8?index=3\""))
    }

    @Test("The Roku-style image rendition is dropped from the rewrite")
    func dropsImageStreamInf() throws {
        let rewritten = try rewrite(
            """
            #EXTM3U
            #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=4170,RESOLUTION=320x180,CODECS="jpeg",URI="Trickplay/320/tiles.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            main.m3u8
            """,
            info: sampleInfo,
        )
        #expect(!rewritten.contains("EXT-X-IMAGE-STREAM-INF"))
    }

    @Test("The mjpg I-frame rendition is appended with the info's geometry")
    func appendsIFrameTag() throws {
        let rewritten = try rewrite("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmain.m3u8\n", info: sampleInfo)
        let expected = "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=4170,CODECS=\"mjpg\",RESOLUTION=320x180,URI=\"custom://iframe.m3u8\""
        #expect(rewritten.hasSuffix(expected + "\n"))
    }

    @Test("A missing server bandwidth falls back to a nominal value")
    func bandwidthFallback() throws {
        let info = TrickplayInfo(
            widthKey: 320, thumbnailWidth: 320, thumbnailHeight: 180,
            columns: 10, rows: 10, intervalMilliseconds: 10000, thumbnailCount: 60,
        )
        let rewritten = try rewrite("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmain.m3u8\n", info: info)
        #expect(rewritten.contains("BANDWIDTH=50000"))
    }

    @Test("A media playlist is refused rather than turned into an invalid hybrid")
    func refusesMediaPlaylist() {
        // The exact shape that crashed the app: appending an I-frame rendition
        // to Jellyfin's main.m3u8 produced a file carrying both media- and
        // master-playlist tags, and MediaToolbox dereferenced a null media
        // playlist parsing it (FigMediaPlaylistGetTargetDuration).
        let mediaPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:6.000000,
        hls1/main/0.mp4
        #EXT-X-ENDLIST
        """
        #expect(TrickplayHLSPlaylist.rewriteMaster(
            mediaPlaylist,
            originalURL: masterURL,
            iframePlaylistURI: "custom://iframe.m3u8",
            info: sampleInfo,
        ) == nil)
    }

    @Test("A nil info rewrites without appending an I-frame rendition")
    func nilInfoSkipsIFrame() throws {
        let rewritten = try rewrite(
            """
            #EXTM3U
            #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=4170,RESOLUTION=320x180,CODECS="jpeg",URI="Trickplay/320/tiles.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            main.m3u8
            """,
            info: nil,
        )
        #expect(!rewritten.contains("EXT-X-I-FRAME-STREAM-INF"))
        #expect(!rewritten.contains("EXT-X-IMAGE-STREAM-INF"))
        #expect(rewritten.contains("https://example.com/jellyfin/Videos/item-1/main.m3u8"))
    }

    @Test("Subtitle renditions are redirected to local routes and collected")
    func redirectsSubtitleRenditions() throws {
        let result = try #require(TrickplayHLSPlaylist.rewriteMaster(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,URI="item-1/Subtitles/2/subtitles.m3u8?SegmentLength=30&ApiKey=tok"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Spanish",URI="item-1/Subtitles/3/subtitles.m3u8?SegmentLength=30&ApiKey=tok"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"
            main.m3u8
            """,
            originalURL: masterURL,
            iframePlaylistURI: "custom://iframe.m3u8",
            info: sampleInfo,
            localSubtitleURI: { "/subs/\($0).m3u8" },
        ))
        #expect(result.playlist.contains("NAME=\"English\",DEFAULT=YES,URI=\"/subs/0.m3u8\""))
        #expect(result.playlist.contains("NAME=\"Spanish\",URI=\"/subs/1.m3u8\""))
        #expect(result.subtitleOriginURLs.map(\.absoluteString) == [
            "https://example.com/jellyfin/Videos/item-1/item-1/Subtitles/2/subtitles.m3u8?SegmentLength=30&ApiKey=tok",
            "https://example.com/jellyfin/Videos/item-1/item-1/Subtitles/3/subtitles.m3u8?SegmentLength=30&ApiKey=tok",
        ])
        // Non-subtitle lines still absolutize to the origin
        #expect(result.playlist.contains("https://example.com/jellyfin/Videos/item-1/main.m3u8"))
    }

    @Test("Without a local route, subtitle renditions absolutize to origin")
    func subtitleRenditionsAbsolutizeByDefault() throws {
        let result = try #require(TrickplayHLSPlaylist.rewriteMaster(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs.m3u8?index=3"
            #EXT-X-STREAM-INF:BANDWIDTH=1000
            main.m3u8
            """,
            originalURL: masterURL,
            iframePlaylistURI: "custom://iframe.m3u8",
            info: sampleInfo,
        ))
        #expect(result.playlist.contains("URI=\"https://example.com/jellyfin/Videos/item-1/subs.m3u8?index=3\""))
        #expect(result.subtitleOriginURLs.isEmpty)
    }

    @Test("I-frame media playlist lists one discrete segment per thumbnail")
    func iframePlaylistStructure() {
        let playlist = TrickplayHLSPlaylist.iframePlaylist(
            info: sampleInfo,
            initializationURI: "custom://init.mp4",
        ) { "custom://seg\($0).m4s" }

        let lines = playlist.split(separator: "\n").map(String.init)
        #expect(lines.first == "#EXTM3U")
        #expect(lines.contains("#EXT-X-I-FRAMES-ONLY"))
        #expect(lines.contains("#EXT-X-TARGETDURATION:10"))
        #expect(lines.contains("#EXT-X-MAP:URI=\"custom://init.mp4\""))
        #expect(lines.filter { $0 == "#EXTINF:10.000," }.count == 60)
        #expect(lines.contains("custom://seg0.m4s"))
        #expect(lines.contains("custom://seg59.m4s"))
        #expect(lines.last == "#EXT-X-ENDLIST")
    }
}

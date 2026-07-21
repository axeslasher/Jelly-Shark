import Foundation
@testable import JellyfinKit
import Testing

@Suite("SubtitleHLSPlaylist")
struct SubtitleHLSPlaylistTests {
    private let playlistURL = URL(
        string: "https://example.com/jellyfin/Videos/item-1/source-1/Subtitles/2/subtitles.m3u8?SegmentLength=30&ApiKey=tok",
    )!

    @Test("Segment URIs are absolutized with AddVttTimeMap stripped")
    func stripsTimeMapParameter() {
        // The exact segment-URI shape Jellyfin 10.11 generates
        let rewritten = SubtitleHLSPlaylist.rewrite(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:30
            #EXT-X-VERSION:3
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:30,
            stream.vtt?CopyTimestamps=true&AddVttTimeMap=true&StartPositionTicks=0&EndPositionTicks=300000000&ApiKey=tok
            #EXTINF:6.093,
            stream.vtt?CopyTimestamps=true&AddVttTimeMap=true&StartPositionTicks=300000000&EndPositionTicks=360930000&ApiKey=tok
            #EXT-X-ENDLIST
            """,
            originalURL: playlistURL,
        )

        #expect(!rewritten.contains("AddVttTimeMap"))
        #expect(rewritten.contains(
            "https://example.com/jellyfin/Videos/item-1/source-1/Subtitles/2/stream.vtt?"
                + "CopyTimestamps=true&StartPositionTicks=0&EndPositionTicks=300000000&ApiKey=tok",
        ))
        // Every segment is rewritten, not just the first
        #expect(rewritten.contains("StartPositionTicks=300000000&EndPositionTicks=360930000"))
    }

    @Test("Tag lines and blank lines pass through untouched")
    func preservesTagLines() {
        let input = """
        #EXTM3U
        #EXT-X-TARGETDURATION:30
        #EXTINF:30,
        stream.vtt?AddVttTimeMap=true&ApiKey=tok
        #EXT-X-ENDLIST
        """
        let rewritten = SubtitleHLSPlaylist.rewrite(input, originalURL: playlistURL)

        #expect(rewritten.hasPrefix("#EXTM3U\n#EXT-X-TARGETDURATION:30\n#EXTINF:30,\n"))
        #expect(rewritten.hasSuffix("#EXT-X-ENDLIST"))
    }

    @Test("Other query parameters survive the rewrite")
    func preservesOtherParameters() {
        let rewritten = SubtitleHLSPlaylist.rewrite(
            "#EXTM3U\nstream.vtt?CopyTimestamps=true&AddVttTimeMap=true&ApiKey=tok\n#EXT-X-ENDLIST",
            originalURL: playlistURL,
        )
        #expect(rewritten.contains("CopyTimestamps=true"))
        #expect(rewritten.contains("ApiKey=tok"))
    }

    @Test("A segment without the parameter still absolutizes")
    func absolutizesUnmappedSegments() {
        let rewritten = SubtitleHLSPlaylist.rewrite(
            "#EXTM3U\nstream.vtt?ApiKey=tok\n#EXT-X-ENDLIST",
            originalURL: playlistURL,
        )
        #expect(rewritten.contains(
            "https://example.com/jellyfin/Videos/item-1/source-1/Subtitles/2/stream.vtt?ApiKey=tok",
        ))
    }

    @Test("Already-absolute segment URIs keep their host")
    func preservesAbsoluteURIs() {
        let rewritten = SubtitleHLSPlaylist.rewrite(
            "#EXTM3U\nhttps://other.example.com/seg.vtt?AddVttTimeMap=true&A=1\n#EXT-X-ENDLIST",
            originalURL: playlistURL,
        )
        #expect(rewritten.contains("https://other.example.com/seg.vtt?A=1"))
    }
}

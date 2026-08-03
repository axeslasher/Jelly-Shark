import Foundation
@testable import JellyfinKit
import Testing

@Suite("HLSMasterCopyVariant")
struct HLSMasterCopyVariantTests {
    /// The three-variant Jellyfin shape captured on the rig (#146, and the
    /// 2026-08-02 copy-variant probe): PQ copy first, injected SDR
    /// re-encodes after, distinguished only by the URI's copy flag.
    private let jellyfinMaster = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=73896268,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,ac-3",RESOLUTION=3840x2160
    main.m3u8?VideoCodec=hevc&AudioCodec=ac3&AllowVideoStreamCopy=true&Tag=abc
    #EXT-X-STREAM-INF:BANDWIDTH=73896268,VIDEO-RANGE=SDR,CODECS="hvc1.2.4.L150.B0,ac-3",RESOLUTION=3840x2160
    main.m3u8?VideoCodec=hevc&AudioCodec=ac3&AllowVideoStreamCopy=false&Tag=abc
    #EXT-X-STREAM-INF:BANDWIDTH=73896268,VIDEO-RANGE=SDR,CODECS="avc1.424029,ac-3",RESOLUTION=3840x2160
    main.m3u8?VideoCodec=h264&AudioCodec=ac3&AllowVideoStreamCopy=false&Tag=abc
    #EXT-X-ENDLIST
    """

    @Test("Picks the variant flagged AllowVideoStreamCopy=true")
    func picksCopyVariant() {
        let uri = HLSMasterCopyVariant.uri(inMaster: jellyfinMaster)
        #expect(uri == "main.m3u8?VideoCodec=hevc&AudioCodec=ac3&AllowVideoStreamCopy=true&Tag=abc")
    }

    @Test("Finds the copy variant even when it is not listed first")
    func copyVariantNotFirst() {
        let reordered = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=SDR,CODECS="avc1.424029"
        main.m3u8?AllowVideoStreamCopy=false
        #EXT-X-STREAM-INF:BANDWIDTH=2,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0"
        main.m3u8?AllowVideoStreamCopy=true
        """
        #expect(HLSMasterCopyVariant.uri(inMaster: reordered) == "main.m3u8?AllowVideoStreamCopy=true")
    }

    @Test("A master with no copy variant yields nil")
    func noCopyVariant() {
        let reEncodeOnly = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=SDR
        main.m3u8?AllowVideoStreamCopy=false
        """
        #expect(HLSMasterCopyVariant.uri(inMaster: reEncodeOnly) == nil)
        #expect(HLSMasterCopyVariant.uri(inMaster: "#EXTM3U\n") == nil)
    }

    @Test("Only variant URIs count — the flag inside a tag line is not a URI")
    func flagOutsideVariantURIIgnored() {
        // A media playlist (no EXT-X-STREAM-INF) whose segment URIs happen
        // to carry the parameter must not be mistaken for a master variant.
        let mediaPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        hls1/main/0.mp4?AllowVideoStreamCopy=true
        """
        #expect(HLSMasterCopyVariant.uri(inMaster: mediaPlaylist) == nil)
    }
}

@Suite("PlaybackCapabilities enhancement-layer widening")
struct EnhancementLayerRangeTests {
    private var capabilities: PlaybackCapabilities {
        PlaybackCapabilities(
            name: "Probe",
            maxStreamingBitrate: 1,
            directPlay: [],
            videoCodecRules: [.init(codec: "hevc", conditions: [
                .init(property: .videoRangeType, comparison: .equalsAny, value: "SDR|HDR10|HLG|DOVIWithHDR10", isRequired: false),
                .init(property: .videoBitDepth, comparison: .lessThanEqual, value: "10", isRequired: false),
            ])],
            subtitles: [],
            transcoding: .init(containers: ["mp4"], videoCodecs: ["hevc"], audioCodecs: ["ac3"], minSegments: 1, breaksOnNonKeyFrames: true),
        )
    }

    @Test("Adds DOVIWithEL to the range condition and nothing else")
    func widensRangeCondition() {
        let widened = capabilities.includingEnhancementLayerRange()
        #expect(widened.videoRangeTypes.contains("DOVIWithEL"))
        #expect(widened.videoRangeTypes.count == capabilities.videoRangeTypes.count + 1)
        // The bit-depth condition is untouched.
        #expect(widened.videoCodecRules[0].conditions[1] == capabilities.videoCodecRules[0].conditions[1])
    }

    @Test("Widening is idempotent")
    func idempotent() {
        let once = capabilities.includingEnhancementLayerRange()
        #expect(once.includingEnhancementLayerRange() == once)
    }
}

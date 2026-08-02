@testable import Features
import Foundation
import JellyfinKit
import Testing

/// The pure decisions behind the progressive remux delivery (#172): which
/// sessions it claims, and how the server reads a Range header. The demux,
/// mux, and layout logic behind them tests in JellyfinKit's host tier; the
/// live end of the path (listener, AVPlayer, tone-mapping) is device-check
/// territory.
@MainActor
@Suite("Progressive delivery")
struct ProgressiveDeliveryTests {
    private func context(
        container: String? = "mkv",
        videoCodec: String? = "hevc",
        videoRange: String? = "HDR10",
    ) -> DeliveryContext {
        DeliveryContext(
            itemId: "item",
            mediaSource: MediaSource(
                id: "source",
                container: container,
                videoCodec: videoCodec,
                videoStream: MediaStreamInfo(index: 0, type: .video, videoRange: videoRange),
            ),
            playSessionId: nil,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil,
            trickplayInfo: nil,
            capabilities: AVFoundationPlayerEngine.capabilities,
        )
    }

    @Test("Claims exactly the HDR MKV on an SDR display")
    func eligibility() {
        #expect(ProgressiveRemuxDelivery.isEligible(context: context(), displaySupportsHDR: false))
        // An HDR display keeps the stream-copy HLS path.
        #expect(!ProgressiveRemuxDelivery.isEligible(context: context(), displaySupportsHDR: true))
        // SDR sources are untouched everywhere.
        #expect(!ProgressiveRemuxDelivery.isEligible(context: context(videoRange: nil), displaySupportsHDR: false))
        // Non-Matroska containers have nothing to demux.
        #expect(!ProgressiveRemuxDelivery.isEligible(context: context(container: "mp4"), displaySupportsHDR: false))
        // Codecs the remux cannot carry stay on the server path.
        #expect(!ProgressiveRemuxDelivery.isEligible(context: context(videoCodec: "vc1"), displaySupportsHDR: false))
    }

    @Test("Selector routes the eligible case progressive, everything else as before")
    func selectorRouting() {
        let hls = StreamResolution(url: URL(string: "https://example.com/master.m3u8")!, playMethod: .directStream)
        let progressive = StreamDeliverySelector.delivery(
            for: hls, context: context(), client: MockJellyfinClient(), displaySupportsHDR: false,
        )
        #expect(progressive is ProgressiveRemuxDelivery)

        let onHDRDisplay = StreamDeliverySelector.delivery(
            for: hls, context: context(), client: MockJellyfinClient(), displaySupportsHDR: true,
        )
        #expect(onHDRDisplay is InterposedHLSDelivery)

        let direct = StreamResolution(url: URL(string: "https://example.com/stream.mkv")!, playMethod: .directPlay)
        let untouched = StreamDeliverySelector.delivery(
            for: direct, context: context(), client: MockJellyfinClient(), displaySupportsHDR: false,
        )
        #expect(untouched is DirectDelivery)
    }

    @Test("Range header parsing covers the forms AVPlayer sends")
    func rangeParsing() {
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=0-1", totalSize: 100) == 0 ..< 2)
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=10-", totalSize: 100) == 10 ..< 100)
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=-20", totalSize: 100) == 80 ..< 100)
        // An end past EOF clamps, per RFC 9110.
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=90-150", totalSize: 100) == 90 ..< 100)
        // A start past EOF is unsatisfiable.
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=100-", totalSize: 100) == nil)
        // Multi-range is refused rather than half-served.
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=0-1,5-6", totalSize: 100) == nil)
        #expect(ProgressiveRemuxServer.parseByteRange("bytes=garbage", totalSize: 100) == nil)
    }
}

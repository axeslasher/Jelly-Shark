@testable import Features
import Foundation
import JellyfinKit
import Testing

/// The pure decisions behind the remux HLS delivery (#172): which sessions
/// it claims. The demux, mux, and playlist logic behind them tests in
/// JellyfinKit's host tier; the live end of the path (listener, AVPlayer,
/// tone-mapping) is device-check territory.
@MainActor
@Suite("Remux HLS delivery")
struct RemuxHLSDeliveryTests {
    private func context(
        container: String? = "mkv",
        videoCodec: String? = "hevc",
        videoRange: String? = "HDR10",
        audioStreamIndex: Int? = nil,
        defaultAudioStreamIndex: Int? = nil,
        audioStreams: [MediaStreamInfo] = [],
        avoidInAppRemux: Bool = false,
    ) -> DeliveryContext {
        DeliveryContext(
            itemId: "item",
            mediaSource: MediaSource(
                id: "source",
                container: container,
                videoCodec: videoCodec,
                defaultAudioStreamIndex: defaultAudioStreamIndex,
                videoStream: MediaStreamInfo(index: 0, type: .video, videoRange: videoRange),
                audioStreams: audioStreams,
            ),
            playSessionId: nil,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: nil,
            trickplayInfo: nil,
            capabilities: AVFoundationPlayerEngine.capabilities,
            avoidInAppRemux: avoidInAppRemux,
        )
    }

    @Test("Claims exactly the HDR MKV on an SDR display")
    func eligibility() {
        #expect(RemuxHLSDelivery.isEligible(context: context(), displaySupportsHDR: false))
        // An HDR display keeps the stream-copy server HLS path.
        #expect(!RemuxHLSDelivery.isEligible(context: context(), displaySupportsHDR: true))
        // SDR sources are untouched everywhere.
        #expect(!RemuxHLSDelivery.isEligible(context: context(videoRange: nil), displaySupportsHDR: false))
        // Non-Matroska containers have nothing to demux.
        #expect(!RemuxHLSDelivery.isEligible(context: context(container: "mp4"), displaySupportsHDR: false))
        // Codecs the remux cannot carry stay on the server path.
        #expect(!RemuxHLSDelivery.isEligible(context: context(videoCodec: "vc1"), displaySupportsHDR: false))
    }

    @Test("Rung 1 declines sessions it could only serve dishonestly")
    func rung1Decline() {
        let streams = [
            MediaStreamInfo(index: 1, type: .audio, codec: "eac3"),
            MediaStreamInfo(index: 2, type: .audio, codec: "ac3"),
        ]
        // The default track with a carriable codec: attempt the remux.
        #expect(RemuxHLSDelivery.rung1DeclineReason(context: context(
            audioStreamIndex: 1, defaultAudioStreamIndex: 1, audioStreams: streams,
        )) == nil)
        // No committed index: the remuxer's pick is the session's claim.
        #expect(RemuxHLSDelivery.rung1DeclineReason(context: context()) == nil)
        // A non-default selection would play the default anyway — descend
        // to the copy variant, which honors it.
        #expect(RemuxHLSDelivery.rung1DeclineReason(context: context(
            audioStreamIndex: 2, defaultAudioStreamIndex: 1, audioStreams: streams,
        )) != nil)
        // A default the remux cannot carry no longer declines: rung 1
        // serves that session with the external-audio path (#249), playing
        // the SAME default track via a server-side audio-only transcode.
        #expect(RemuxHLSDelivery.rung1DeclineReason(context: context(
            audioStreamIndex: 1,
            defaultAudioStreamIndex: 1,
            audioStreams: [MediaStreamInfo(index: 1, type: .audio, codec: "dts")],
        )) == nil)
        // A prior mid-file failure pins the session below rung 1.
        #expect(RemuxHLSDelivery.rung1DeclineReason(context: context(avoidInAppRemux: true)) != nil)
    }

    @Test("Selector routes the eligible case to remux HLS, everything else as before")
    func selectorRouting() {
        let hls = StreamResolution(url: URL(string: "https://example.com/master.m3u8")!, playMethod: .directStream)
        let remuxed = StreamDeliverySelector.delivery(
            for: hls, context: context(), client: MockJellyfinClient(), displaySupportsHDR: false,
        )
        #expect(remuxed is RemuxHLSDelivery)

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
}

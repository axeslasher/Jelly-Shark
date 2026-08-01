@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("StreamDelivery")
@MainActor
struct StreamDeliveryTests {
    /// A cancelled stream build unwinding through `prepare()` must not be
    /// mistaken for a degraded-listener session: no re-resolve, no fallback
    /// URL swap — the caller's supersede guard discards the result anyway
    /// (#212). A genuine listener failure without cancellation still takes
    /// the degraded re-resolve.
    @Test("prepare() on a cancelled task unwinds without the degraded re-resolve")
    func prepareOnCancelledTaskSkipsDegradedFallback() async {
        let client = MockJellyfinClient()
        let origin = URL(string: "https://origin.example/Videos/item-1/master.m3u8")!
        let resolution = StreamResolution(url: origin, playMethod: .directStream)
        let delivery = InterposedHLSDelivery(
            resolution: resolution,
            context: DeliveryContext(
                itemId: "item-1",
                mediaSource: MediaSource(id: "source-1"),
                playSessionId: "session-1",
                audioStreamIndex: nil,
                subtitleStreamIndex: nil,
                trickplayInfo: nil,
                capabilities: AVFoundationPlayerEngine.capabilities,
            ),
            client: client,
        )
        defer { delivery.stop() }

        let delivered = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await delivery.prepare()
        }.value

        #expect(delivered.url == origin)
        #expect(delivered.playMethod == .directStream)
        #expect(client.streamResolutions.isEmpty)
    }
}

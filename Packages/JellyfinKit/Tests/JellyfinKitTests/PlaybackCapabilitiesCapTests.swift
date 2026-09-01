@testable import JellyfinKit
import Testing

/// The user-set streaming ceiling (#168) as a narrowing of the engine's
/// declaration: it may only lower `maxStreamingBitrate`, and it may not touch
/// anything else in the profile.
@Suite("Streaming quality cap")
struct PlaybackCapabilitiesCapTests {
    private let declared = PlaybackCapabilities.jellySharkAVFoundationFixture

    @Test("No cap is the identity, so an untouched install negotiates as before")
    func noCapIsIdentity() {
        #expect(declared.cappedStreamingBitrate(to: nil) == declared)
        #expect(declared.cappedStreamingBitrate(to: StreamingQualityTier.maximum.bitsPerSecond) == declared)
    }

    @Test("A cap lowers the ceiling and moves nothing else")
    func capLowersOnlyTheCeiling() {
        let capped = declared.cappedStreamingBitrate(to: 2_000_000)
        #expect(capped.maxStreamingBitrate == 2_000_000)

        // Codec, range and subtitle claims stay facts about the engine's
        // decoder — a slow link does not change what it can decode.
        var expected = declared
        expected.maxStreamingBitrate = 2_000_000
        #expect(capped == expected)
    }

    @Test("A cap can never widen the declaration")
    func capNeverWidens() {
        let widened = declared.cappedStreamingBitrate(to: declared.maxStreamingBitrate * 2)
        #expect(widened.maxStreamingBitrate == declared.maxStreamingBitrate)
    }

    @Test("Every tier below Maximum caps to its own bitrate")
    func tiersCapToTheirBitrate() {
        #expect(StreamingQualityTier.maximum.bitsPerSecond == nil)
        for tier in StreamingQualityTier.allCases where tier != .maximum {
            #expect(tier.bitsPerSecond == tier.rawValue)
            let capped = declared.cappedStreamingBitrate(to: tier.bitsPerSecond)
            #expect(capped.maxStreamingBitrate == tier.rawValue)
        }
    }

    @Test("The shipped tiers are the agreed set, highest first")
    func shippedTiers() {
        // `allCases` is what Settings renders, in declaration order. Raw
        // values are bits per second, so reordering or dropping a tier can
        // never remap someone's persisted choice to a different speed.
        #expect(StreamingQualityTier.allCases.map(\.rawValue) == [
            0,
            40_000_000,
            20_000_000,
            8_000_000,
            4_000_000,
            2_000_000,
        ])
    }
}

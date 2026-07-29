@testable import Features
import JellyfinKit
import Testing

/// Pins `AVFoundationPlayerEngine.capabilities` to the exact values the
/// retired hardcoded `DeviceProfile` carried (#85): "same values, new
/// owner" as an assertable claim. The JellyfinKit host suite proves the
/// builder translates a matching fixture into the identical wire payload;
/// this proves the real declaration matches that fixture.
@Suite("AVFoundationPlayerEngine capabilities")
@MainActor
struct PlaybackCapabilitiesDeclarationTests {
    private let capabilities = AVFoundationPlayerEngine.capabilities

    @Test("Identity and bitrate ceiling")
    func identityAndBitrate() {
        #expect(capabilities.name == "Jelly Shark")
        // Omitting the budget makes the server report
        // SupportsDirectPlay=false for most real files (~2.5 Mbps default)
        #expect(capabilities.maxStreamingBitrate == 120_000_000)
    }

    @Test("Direct play claims the mp4 family with hardware codecs")
    func directPlayClaims() throws {
        let rule = try #require(capabilities.directPlay.first)
        #expect(capabilities.directPlay.count == 1)
        #expect(rule.containers == ["mp4", "m4v", "mov"])
        #expect(rule.videoCodecs == ["hevc", "h264"])
        #expect(rule.audioCodecs == ["aac", "ac3", "eac3", "flac", "alac"])
    }

    @Test("The hvc1 tag requirement stays scoped to containers that carry tags")
    func codecTagRule() throws {
        // MKV streams have no sample-entry tag; an unscoped required
        // condition forced a pointless re-encode of every HEVC MKV (#146)
        let rule = try #require(capabilities.videoCodecRules.first { rule in
            rule.conditions.contains { $0.property == .videoCodecTag }
        })
        #expect(rule.codec == "hevc")
        #expect(rule.containers == ["mp4", "m4v", "mov"])
        let condition = try #require(rule.conditions.first)
        #expect(condition.value == "hvc1|dvh1")
        #expect(condition.isRequired)
    }

    @Test("Video ranges declare HDR without either Dolby Vision single-source profile")
    func videoRanges() {
        // DOVIWithEL absent selects the server's strip-to-HDR10 copy path;
        // DOVI (profile 5) absent pending on-device DV signaling checks
        #expect(capabilities.videoRangeTypes == ["SDR", "HDR10", "HLG", "DOVIWithHDR10"])
        #expect(capabilities.hevcRangeTypesParameter == "SDR,HDR10,HLG,DOVIWithHDR10")
    }

    @Test("H.264 is capped at 8-bit mainstream profiles, advisorily")
    func h264Rule() throws {
        let rule = try #require(capabilities.videoCodecRules.first { $0.codec == "h264" })
        #expect(rule.containers == nil)
        #expect(rule.conditions.count == 2)
        #expect(rule.conditions.allSatisfy { !$0.isRequired })
        let depth = try #require(rule.conditions.first { $0.property == .videoBitDepth })
        #expect(depth.comparison == .lessThanEqual)
        #expect(depth.value == "8")
        let profile = try #require(rule.conditions.first { $0.property == .videoProfile })
        #expect(profile.value == "high|main|baseline|constrained baseline")
    }

    @Test("Image and styled subtitle formats still burn in — the #175/#177 frontier")
    func subtitleDeliveries() {
        // When on-device rendering lands, those issues amend THIS
        // declaration (formats move off .encode) — the profile and the
        // TranscodeReasons the server reports follow automatically
        let encoded = capabilities.subtitles.filter { $0.delivery == .encode }.map(\.format)
        #expect(encoded == ["ass", "ssa", "pgssub", "dvdsub"])
        #expect(capabilities.subtitles.contains(.init(format: "mov_text", delivery: .embed)))
        for format in ["vtt", "subrip"] {
            #expect(capabilities.subtitles.contains(.init(format: format, delivery: .external)))
            #expect(capabilities.subtitles.contains(.init(format: format, delivery: .hls)))
        }
    }

    @Test("Transcoding accepts both segment containers StreamURLBuilder requests")
    func transcodingRule() {
        let rule = capabilities.transcoding
        #expect(rule.containers == ["mp4", "ts"])
        #expect(rule.videoCodecs == ["hevc", "h264"])
        #expect(rule.audioCodecs == ["aac", "ac3", "eac3"])
        #expect(rule.minSegments == 2)
        #expect(rule.breaksOnNonKeyFrames)
    }

    @Test("Playback flows send the engine's declaration to the server")
    func declarationReachesTheClient() async {
        let client = MockJellyfinClient()
        let engine = MockPlayerEngine()
        let viewModel = PlaybackViewModel(client: client, item: MediaItem(id: "m1", name: "Movie", type: .movie), engine: engine)

        await viewModel.start()

        #expect(client.receivedCapabilities == [engine.capabilities])
    }
}

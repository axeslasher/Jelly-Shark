import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

@Suite("DeviceProfile")
struct DeviceProfileTests {
    private var hevcProfiles: [JellyfinAPI.CodecProfile] {
        (JellyfinClient.deviceProfile.codecProfiles ?? [])
            .filter { $0.codec == "hevc" && $0.type == .video }
    }

    @Test("HEVC codec tag condition is scoped to containers that carry tags")
    func codecTagScopedToMP4Family() throws {
        // MKV streams have no sample-entry tag (CodecTag=null), so an
        // unscoped required tag condition fails every HEVC MKV and forces a
        // needless video re-encode (#146). The condition must stay for the
        // mp4 family, where an hev1 tag really is unplayable directly.
        let tagProfile = try #require(hevcProfiles.first { profile in
            profile.conditions?.contains { $0.property == .videoCodecTag } == true
        })
        #expect(tagProfile.container == "mp4,m4v,mov")

        let condition = try #require(tagProfile.conditions?.first { $0.property == .videoCodecTag })
        #expect(condition.condition == .equalsAny)
        #expect(condition.isRequired == true)
        #expect(condition.value == "hvc1|dvh1")
    }

    @Test("HEVC range declaration covers HDR and applies to every container")
    func rangeTypeDeclared() throws {
        // Without a range declaration the server assumes SDR-only and
        // tone-maps HDR via a below-realtime software re-encode (#146)
        let rangeProfile = try #require(hevcProfiles.first { profile in
            profile.conditions?.contains { $0.property == .videoRangeType } == true
        })
        #expect(rangeProfile.container == nil)

        let condition = try #require(rangeProfile.conditions?.first { $0.property == .videoRangeType })
        #expect(condition.condition == .equalsAny)
        // Unprobed sources must not be rejected outright
        #expect(condition.isRequired == false)
        // DOVIWithEL (DV profile 7) deliberately absent — its omission
        // selects the server's strip-to-HDR10 copy path. DOVI (profile 5)
        // deliberately absent pending on-device DV signaling verification.
        #expect(condition.value == "SDR|HDR10|HLG|DOVIWithHDR10")

        // The stream URL sends the same set, comma-separated, so the
        // PlaybackInfo negotiation and the hand-built HLS URL agree
        let urlSet = StreamURLBuilder.hevcRangeTypes.split(separator: ",").sorted()
        let profileSet = (condition.value ?? "").split(separator: "|").sorted()
        #expect(urlSet == profileSet)
    }
}

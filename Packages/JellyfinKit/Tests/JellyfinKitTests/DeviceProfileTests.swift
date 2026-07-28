import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

@Suite("DeviceProfile")
struct DeviceProfileTests {
    private var profile: JellyfinAPI.DeviceProfile {
        JellyfinAPI.DeviceProfile(capabilities: .jellySharkAVFoundationFixture)
    }

    private var hevcProfiles: [JellyfinAPI.CodecProfile] {
        (profile.codecProfiles ?? [])
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
    }

    @Test("The stream URL's range parameter reads the same stored condition")
    func rangeParameterSharesTheStoredCondition() {
        // Both serializations come from the one videoRangeType condition,
        // so PlaybackInfo negotiation (pipe-joined in the profile) and the
        // hand-built HLS URL (comma-joined) agree by construction
        let capabilities = PlaybackCapabilities.jellySharkAVFoundationFixture
        #expect(capabilities.videoRangeTypes == ["SDR", "HDR10", "HLG", "DOVIWithHDR10"])
        #expect(capabilities.hevcRangeTypesParameter == "SDR,HDR10,HLG,DOVIWithHDR10")
    }

    @Test("The derived profile is byte-identical to the retired hardcoded literal")
    func derivedProfileMatchesRetiredLiteral() throws {
        // The refactor's claim is "same wire payload, new owner" (#85).
        // This proves it against the literal that shipped before the
        // derivation existed. TEMPORARY: this test and its literal are
        // removed once green — kept permanent it would block every
        // legitimate future capability change (#175, #176).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let derived = try encoder.encode(profile)
        let literal = try encoder.encode(Self.retiredHardcodedProfile)

        #expect(derived == literal)
    }

    /// The exact literal `JellyfinClient.deviceProfile` shipped before #85
    /// derived the profile from `PlaybackCapabilities`
    private static var retiredHardcodedProfile: JellyfinAPI.DeviceProfile {
        JellyfinAPI.DeviceProfile(
            codecProfiles: [
                JellyfinAPI.CodecProfile(
                    codec: "hevc",
                    conditions: [
                        JellyfinAPI.ProfileCondition(
                            condition: .equalsAny,
                            isRequired: true,
                            property: .videoCodecTag,
                            value: "hvc1|dvh1",
                        ),
                    ],
                    container: "mp4,m4v,mov",
                    type: .video,
                ),
                JellyfinAPI.CodecProfile(
                    codec: "hevc",
                    conditions: [
                        JellyfinAPI.ProfileCondition(
                            condition: .equalsAny,
                            isRequired: false,
                            property: .videoRangeType,
                            value: "SDR|HDR10|HLG|DOVIWithHDR10",
                        ),
                    ],
                    type: .video,
                ),
                JellyfinAPI.CodecProfile(
                    codec: "h264",
                    conditions: [
                        JellyfinAPI.ProfileCondition(
                            condition: .lessThanEqual,
                            isRequired: false,
                            property: .videoBitDepth,
                            value: "8",
                        ),
                        JellyfinAPI.ProfileCondition(
                            condition: .equalsAny,
                            isRequired: false,
                            property: .videoProfile,
                            value: "high|main|baseline|constrained baseline",
                        ),
                    ],
                    type: .video,
                ),
            ],
            directPlayProfiles: [
                JellyfinAPI.DirectPlayProfile(
                    audioCodec: "aac,ac3,eac3,flac,alac",
                    container: "mp4,m4v,mov",
                    type: .video,
                    videoCodec: "hevc,h264",
                ),
            ],
            name: "Jelly Shark",
            subtitleProfiles: [
                JellyfinAPI.SubtitleProfile(format: "mov_text", method: .embed),
                JellyfinAPI.SubtitleProfile(format: "vtt", method: .external),
                JellyfinAPI.SubtitleProfile(format: "subrip", method: .external),
                JellyfinAPI.SubtitleProfile(format: "vtt", method: .hls),
                JellyfinAPI.SubtitleProfile(format: "subrip", method: .hls),
                JellyfinAPI.SubtitleProfile(format: "ass", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "ssa", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "pgssub", method: .encode),
                JellyfinAPI.SubtitleProfile(format: "dvdsub", method: .encode),
            ],
            transcodingProfiles: [
                JellyfinAPI.TranscodingProfile(
                    audioCodec: "aac,ac3,eac3",
                    isBreakOnNonKeyFrames: true,
                    container: "mp4,ts",
                    context: .streaming,
                    minSegments: 2,
                    protocol: .hls,
                    type: .video,
                    videoCodec: "hevc,h264",
                ),
            ],
        )
    }
}

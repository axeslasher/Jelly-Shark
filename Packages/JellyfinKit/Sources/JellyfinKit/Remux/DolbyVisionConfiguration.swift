import Foundation

// Dolby Vision handling for the MKV remux (#176).
//
// Two jobs:
//  1. Interpret the DOVIDecoderConfigurationRecord a Matroska source hands us
//     via BlockAdditionMapping (the box ffmpeg refuses to write — spike
//     finding 3), and decide what to signal for what tvOS actually decodes
//     (profiles 5/8 pass through; profile 7 is carried unsignalled).
//  2. Strip profile 7's enhancement layer: single-track profile 7 carries
//     its EL as UNSPEC63 NALUs at layer 0, dropped so the delivered stream
//     is the shape verified on-device. The stream is then carried
//     UNSIGNALLED — no DV box — per `signalledForAVFoundation()`, which
//     holds the device evidence for why relabelling as 8.1 was abandoned.
//     Measured in the spike: the EL of a MEL source is 0.05% of payload,
//     smaller than the RPU itself.

/// The 24-byte DOVIDecoderConfigurationRecord — the payload of a `dvcC`
/// (profiles ≤ 7) or `dvvC` (profiles ≥ 8) box.
public struct DolbyVisionConfiguration: Sendable, Equatable {
    public var versionMajor: UInt8
    public var versionMinor: UInt8
    public var profile: UInt8
    public var level: UInt8
    public var rpuPresent: Bool
    public var elPresent: Bool
    public var blPresent: Bool
    public var blSignalCompatibilityID: UInt8

    /// Parse a 24-byte record, or a full `dvcC`/`dvvC` box (Matroska sources
    /// differ in whether BlockAddIDExtraData includes the box header).
    public init?(recordOrBox data: Data) {
        var record = data
        if data.count >= 8 {
            let boxType = String(decoding: data.subdata(in: (data.startIndex + 4) ..< (data.startIndex + 8)), as: UTF8.self)
            if boxType == "dvcC" || boxType == "dvvC" {
                record = data.subdata(in: (data.startIndex + 8) ..< data.endIndex)
            }
        }
        guard record.count >= 5 else { return nil }
        let b = [UInt8](record)
        versionMajor = b[0]
        versionMinor = b[1]
        // dv_profile (7 bits) + dv_level (6 bits) + rpu/el/bl flags (1 each)
        profile = b[2] >> 1
        level = ((b[2] & 0x01) << 5) | (b[3] >> 3)
        rpuPresent = b[3] & 0x04 != 0
        elPresent = b[3] & 0x02 != 0
        blPresent = b[3] & 0x01 != 0
        blSignalCompatibilityID = record.count > 4 ? (b[4] >> 4) : 0
    }

    public init(
        profile: UInt8,
        level: UInt8,
        rpuPresent: Bool,
        elPresent: Bool,
        blPresent: Bool,
        blSignalCompatibilityID: UInt8,
    ) {
        versionMajor = 1
        versionMinor = 0
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.elPresent = elPresent
        self.blPresent = blPresent
        self.blSignalCompatibilityID = blSignalCompatibilityID
    }

    /// The configuration to actually signal in the fMP4, or `nil` when the
    /// source's Dolby Vision cannot be carried and playback should fall back
    /// to plain HDR10 (no DV box at all).
    ///
    /// - Profile 8 passes through unchanged.
    /// - Profile 7 is UNSIGNALLED, so the fMP4 carries the HDR10 base layer
    ///   with no DV box. Relabelling the configuration record as 8.1 was
    ///   tried and is wrong: it leaves the source's profile-7 RPU in the
    ///   stream, and that RPU describes a DUAL-LAYER reconstruction (NLQ
    ///   coefficients for the EL residual) that 8.1 does not have. The
    ///   display pipeline then engages the DV composer, applies two-layer
    ///   mapping metadata to a base layer whose EL has just been stripped,
    ///   and renders severe chroma corruption — device-measured 2026-08-11
    ///   on the SDR-panel rig across four profile-7 sources, every one a
    ///   green/magenta ruin while profile-8.1 sources on the identical code
    ///   path were correct. An honest conversion has to REWRITE the RPU
    ///   (what `dovi_tool --mode 2` does), which this remuxer does not do.
    ///   Unsignalled is the same shape the copy-variant rung serves — the
    ///   bitstream keeps its unspec62/63 NALUs, nothing claims Dolby Vision,
    ///   the decoder ignores them, and the base layer renders correctly
    ///   (device-verified the same day). This delivery only ever serves SDR
    ///   displays, which tone-map either way, so no DV rendering is lost.
    /// - Profile 5 (no base-layer compatibility) passes through: tvOS decodes
    ///   it, and there is nothing to convert.
    /// - Anything else is unsignalled rather than mis-signalled.
    public func signalledForAVFoundation() -> DolbyVisionConfiguration? {
        switch profile {
        case 5, 8:
            self
        default:
            nil
        }
    }

    /// Whether ``HEVCNALFilter`` must strip enhancement-layer NALUs.
    ///
    /// Still true for profile 7 even though it is now unsignalled. Not for
    /// bandwidth — the measured source's EL is a MEL at 0.05% of video
    /// payload (PLAYBACK_MATRIX.md), so the saving is nil — but because
    /// stripping is the shape verified end to end on the SDR-panel rig
    /// (2026-08-11, three profile-7 sources, correct picture). An
    /// unsignalled EL is inert, so dropping the filter would probably also
    /// work; "probably" is not what this path is short of.
    public var requiresEnhancementLayerFilter: Bool {
        profile == 7
    }

    /// Serialize as the full box (`dvcC` for profiles ≤ 7, `dvvC` above).
    public func boxData() -> Data {
        var record = Data(capacity: 24)
        record.append(versionMajor)
        record.append(versionMinor)
        record.append((profile << 1) | (level >> 5))
        record.append(
            ((level & 0x1F) << 3)
                | (rpuPresent ? 0x04 : 0)
                | (elPresent ? 0x02 : 0)
                | (blPresent ? 0x01 : 0),
        )
        record.append(blSignalCompatibilityID << 4)
        record.append(Data(count: 24 - record.count))
        let type = profile >= 8 ? "dvvC" : "dvcC"
        var box = Data()
        var size = UInt32(8 + record.count).bigEndian
        withUnsafeBytes(of: &size) { box.append(contentsOf: $0) }
        box.append(Data(type.utf8))
        box.append(record)
        return box
    }
}

public extension MatroskaTrack {
    /// The Dolby Vision configuration the source declares for this track, if
    /// any. Matroska registers the mapping type as the box fourcc.
    var dolbyVisionConfiguration: DolbyVisionConfiguration? {
        for mapping in blockAdditionMappings {
            let fourcc = mapping.type
            let name = String(bytes: [
                UInt8((fourcc >> 24) & 0xFF), UInt8((fourcc >> 16) & 0xFF),
                UInt8((fourcc >> 8) & 0xFF), UInt8(fourcc & 0xFF),
            ], encoding: .ascii)
            guard name == "dvcC" || name == "dvvC" || name == "hvcE",
                  let extra = mapping.extraData,
                  let config = DolbyVisionConfiguration(recordOrBox: extra)
            else { continue }
            return config
        }
        return nil
    }
}

/// Walks length-prefixed HEVC access units and drops profile 7's
/// enhancement-layer NALUs (the stream is then delivered unsignalled — no DV
/// box — per `signalledForAVFoundation()`).
///
/// Single-track profile 7 remaps its layers instead of using `nuh_layer_id`:
/// the enhancement layer is NAL type 63 (UNSPEC63) and the RPU is type 62
/// (UNSPEC62), both at layer 0 — the spike's probe bug #2 was testing for
/// `nuh_layer_id == 1` and missing an EL that was plainly there.
public enum HEVCNALFilter {
    /// Only the enhancement layer is dropped. The RPU (62) stays in the
    /// bitstream but is inert: nothing signals Dolby Vision, so the decoder
    /// ignores it — the device-verified shape (see
    /// `requiresEnhancementLayerFilter`).
    private static let enhancementLayerType: UInt8 = 63

    /// Returns `sample` with UNSPEC63 NALUs removed, or `nil` when the
    /// sample's length prefixes do not parse (caller should treat the source
    /// as malformed rather than pass the bitstream through unfiltered).
    ///
    /// - Parameter lengthSize: NAL length prefix width from the `hvcC`
    ///   (`lengthSizeMinusOne + 1`); almost always 4, but the spike's probe
    ///   bug #1 came from assuming it.
    public static func droppingEnhancementLayer(from sample: Data, lengthSize: Int) -> Data? {
        guard lengthSize >= 1, lengthSize <= 4 else { return nil }
        var output = Data(capacity: sample.count)
        var offset = sample.startIndex
        let end = sample.endIndex
        while offset < end {
            guard end - offset > lengthSize else { return nil }
            var length = 0
            for i in 0 ..< lengthSize {
                length = (length << 8) | Int(sample[offset + i])
            }
            let nalStart = offset + lengthSize
            guard length > 0, end - nalStart >= length else { return nil }
            // nal_unit_type is bits 1-6 of the first NAL header byte
            let nalType = (sample[nalStart] >> 1) & 0x3F
            if nalType != enhancementLayerType {
                output.append(sample[offset ..< nalStart + length])
            }
            offset = nalStart + length
        }
        return output
    }
}

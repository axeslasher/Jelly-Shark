import Foundation

// Dolby Vision handling for the MKV remux (#176).
//
// Two jobs:
//  1. Interpret the DOVIDecoderConfigurationRecord a Matroska source hands us
//     via BlockAdditionMapping (the box ffmpeg refuses to write — spike
//     finding 3), and re-author it for what tvOS actually decodes.
//  2. Filter profile-7 bitstreams down to profile 8.1: Apple does not decode
//     profile 7 (a disc format), but single-track profile 7 carries its
//     enhancement layer as UNSPEC63 NALUs at layer 0 that can simply be
//     dropped — the base slices and the UNSPEC62 RPU are the 8.1 stream.
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
    /// - Profile 7 becomes 8.1: the EL is dropped by ``HEVCNALFilter``, so
    ///   `elPresent` clears, and the compatibility ID maps to 1 (HDR10) —
    ///   profile-7 sources declare 6 (UHD Blu-ray), which implies an
    ///   HDR10-compatible base layer, and 1 is what HLS `db1p` signalling
    ///   means on the Apple side.
    /// - Profile 5 (no base-layer compatibility) passes through: tvOS decodes
    ///   it, and there is nothing to convert.
    /// - Anything else is unsignalled rather than mis-signalled.
    public func signalledForAVFoundation() -> DolbyVisionConfiguration? {
        switch profile {
        case 5, 8:
            return self
        case 7:
            guard blPresent, rpuPresent else { return nil }
            return DolbyVisionConfiguration(
                profile: 8,
                level: level,
                rpuPresent: true,
                elPresent: false,
                blPresent: true,
                blSignalCompatibilityID: 1,
            )
        default:
            return nil
        }
    }

    /// Whether ``HEVCNALFilter`` must strip enhancement-layer NALUs before
    /// this configuration's `signalledForAVFoundation()` form is honest.
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

/// Walks length-prefixed HEVC access units and drops the NAL types that must
/// not survive a profile-7 → 8.1 conversion.
///
/// Single-track profile 7 remaps its layers instead of using `nuh_layer_id`:
/// the enhancement layer is NAL type 63 (UNSPEC63) and the RPU is type 62
/// (UNSPEC62), both at layer 0 — the spike's probe bug #2 was testing for
/// `nuh_layer_id == 1` and missing an EL that was plainly there.
public enum HEVCNALFilter {
    /// NAL unit types to drop for 8.1: the enhancement layer only. The RPU
    /// (62) stays — it is what makes the stream Dolby Vision.
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

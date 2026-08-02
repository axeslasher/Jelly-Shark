import Foundation

// EBML primitives for the Matroska demuxer (#176). Promoted from the spike in
// docs/spikes/176-mkv-demux (deleted when this landed); the parsing rules are
// unchanged so results stay comparable with the spike's measurements.

/// EBML variable-width integers: the number of leading zero bits in the first
/// byte (plus one) is the total byte width.
enum EBML {
    static func width(ofFirstByte b: UInt8) -> Int {
        guard b != 0 else { return 0 }
        var mask: UInt8 = 0x80
        for i in 1 ... 8 {
            if b & mask != 0 {
                return i
            }
            mask >>= 1
        }
        return 0
    }
}

/// A parse position over a fetched window of the file. `base` is the window's
/// absolute file offset, so `absolute` positions survive ranged fetching.
struct EBMLCursor {
    let data: Data
    let base: UInt64
    var pos: Int = 0

    var absolute: UInt64 {
        base + UInt64(pos)
    }

    var remaining: Int {
        data.count - pos
    }

    mutating func byte() -> UInt8? {
        guard pos < data.count else { return nil }
        defer { pos += 1 }
        return data[data.startIndex + pos]
    }

    func peek(_ n: Int) -> Data? {
        guard n >= 0, pos + n <= data.count else { return nil }
        return data[(data.startIndex + pos) ..< (data.startIndex + pos + n)]
    }

    mutating func take(_ n: Int) -> Data? {
        guard let d = peek(n) else { return nil }
        pos += n
        return d
    }

    mutating func skip(_ n: Int) {
        pos = min(pos + n, data.count)
    }

    /// Element IDs keep their length-marker bit, per the EBML spec.
    mutating func readID() -> UInt32? {
        guard let first = peek(1)?.first else { return nil }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, w <= 4, let raw = take(w) else { return nil }
        return raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Element sizes drop the marker bit. An all-ones value means "unknown
    /// size" (streamed muxes), returned as `.some(nil)`; a malformed VINT is
    /// `nil`.
    mutating func readSize() -> Int?? {
        guard let first = peek(1)?.first else { return nil }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, let raw = take(w) else { return nil }
        var value = UInt64(raw[raw.startIndex] & (0xFF >> UInt8(w)))
        for b in raw.dropFirst() {
            value = (value << 8) | UInt64(b)
        }
        let allOnes = (UInt64(1) << (7 * UInt64(w))) - 1
        if value == allOnes {
            return .some(nil)
        }
        return .some(Int(value))
    }

    /// A signed VINT (used by EBML lacing deltas): the unsigned value minus
    /// the mid-point of its width's range.
    mutating func readSignedVINT() -> Int? {
        guard let first = peek(1)?.first else { return nil }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, let raw = take(w) else { return nil }
        var value = UInt64(raw[raw.startIndex] & (0xFF >> UInt8(w)))
        for b in raw.dropFirst() {
            value = (value << 8) | UInt64(b)
        }
        let bias = (UInt64(1) << (7 * UInt64(w) - 1)) - 1
        return Int(Int64(bitPattern: value) - Int64(bias))
    }

    static func uint(_ d: Data) -> UInt64 {
        d.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func float(_ d: Data) -> Double {
        if d.count == 4 {
            return Double(Float(bitPattern: UInt32(uint(d))))
        }
        if d.count == 8 {
            return Double(bitPattern: uint(d))
        }
        return 0
    }
}

/// The Matroska element IDs the demuxer walks. Read-only scope: only what an
/// fMP4 remux needs — no Chapters, Tags, or Attachments.
enum MatroskaID {
    static let ebmlHeader: UInt32 = 0x1A45_DFA3
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagDefault: UInt32 = 0x88
    static let defaultDuration: UInt32 = 0x23E383
    static let language: UInt32 = 0x22B59C
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0
    static let audio: UInt32 = 0xE1
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let channels: UInt32 = 0x9F
    static let samplingFrequency: UInt32 = 0xB5
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cluster: UInt32 = 0x1F43_B675
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let referenceBlock: UInt32 = 0xFB
    static let blockDuration: UInt32 = 0x9B
    // Dolby Vision configuration travels at the track level: a
    // BlockAdditionMapping whose extra data is the dvcC/dvvC box ffmpeg
    // refuses to write (#176 spike finding 3).
    static let blockAdditionMapping: UInt32 = 0x41E4
    static let blockAddIDValue: UInt32 = 0x41F0
    static let blockAddIDType: UInt32 = 0x41E7
    static let blockAddIDExtraData: UInt32 = 0x41ED
}

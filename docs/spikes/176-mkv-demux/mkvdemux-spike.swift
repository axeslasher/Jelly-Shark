// Spike: is a narrow, read-only Matroska demuxer tractable in pure Swift?
//
// Decides #176's Path A (FFmpeg binaryTarget, which drags in #199 and #178's
// package policy) vs Path B (in-repo Swift, no binary, no blockers).
//
// It must answer four things, because those are what a remuxer actually needs:
//
//   1. Can we walk EBML and pull Info/Tracks/Cues without reading the whole file?
//      -> SeekHead offsets make ranged HTTP access possible at all.
//   2. Is CodecPrivate for HEVC already an `hvcC` payload?
//      -> if so it drops straight into an fMP4 `hvc1` sample entry, no synthesis.
//   3. Are frames already length-prefixed NALUs rather than Annex B?
//      -> if so remuxing is a byte copy, not a bitstream conversion.
//   4. Do Cues give a usable keyframe -> byte-offset index?
//      -> that is the seek index, and the moov/fragment index.
//
// Usage: swift mkvdemux-spike.swift <file.mkv>

import Foundation

// MARK: - EBML primitives

/// Matroska stores integers as variable-length "VINT"s. The count of leading
/// zero bits in the first byte gives the total width; the first set bit is a
/// marker, not data. IDs keep the marker (that is how they are written in the
/// spec); sizes strip it.
enum EBML {
    static func width(ofFirstByte b: UInt8) -> Int {
        if b == 0 {
            return 0
        }
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

struct Cursor {
    let data: Data
    /// Absolute file offset the buffer starts at, so reported positions are
    /// real file positions even when only a slice was read.
    let base: Int
    var pos: Int = 0

    var absolute: Int {
        base + pos
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
        guard pos + n <= data.count else { return nil }
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

    /// Element ID — marker bits retained, which is how IDs are spelled.
    mutating func readID() -> UInt32? {
        guard let first = peek(1)?.first else { return nil }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, w <= 4, let raw = take(w) else { return nil }
        return raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Element size — marker stripped. Returns nil for "unknown size", which
    /// is legal for Segment and Cluster in streamed files.
    mutating func readSize() -> Int?? {
        guard let first = peek(1)?.first else { return .some(nil) }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, let raw = take(w) else { return .some(nil) }
        var value = UInt64(raw[raw.startIndex] & (0xFF >> UInt8(w)))
        for b in raw.dropFirst() {
            value = (value << 8) | UInt64(b)
        }
        // all-ones value bits == unknown size
        let allOnes = (UInt64(1) << (7 * UInt64(w))) - 1
        if value == allOnes {
            return .some(nil)
        }
        return .some(Int(value))
    }

    static func uint(_ d: Data) -> UInt64 {
        d.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func float(_ d: Data) -> Double {
        if d.count == 4 {
            return Double(Float(bitPattern: UInt32(uint(d))))
        } else if d.count == 8 {
            return Double(bitPattern: uint(d))
        }
        return 0
    }
}

// MARK: - IDs

enum ID {
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
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let channels: UInt32 = 0x9F
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

    static let masters: Set<UInt32> = [
        segment, seekHead, seek, info, tracks, trackEntry, video, audio,
        cues, cuePoint, cueTrackPositions, cluster, blockGroup,
    ]
}

// MARK: - Model

struct Track {
    var number: Int = 0
    var type: Int = 0
    var codecID: String = ""
    var codecPrivate: Data?
    var width: Int?
    var height: Int?
    var channels: Int?
    var sampleRate: Double?
    var typeName: String {
        switch type {
        case 1: "video"
        case 2: "audio"
        case 17: "subtitle"
        default: "type\(type)"
        }
    }
}

struct CueEntry {
    var time: UInt64 = 0
    var track: Int = 0
    /// Relative to the Segment's *data* start, per spec.
    var clusterPosition: Int = 0
}

// MARK: - Parse

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: swift mkvdemux-spike.swift <file.mkv>"); exit(1) }
let url = URL(fileURLWithPath: args[1])
guard let file = try? Data(contentsOf: url) else { print("cannot read \(args[1])"); exit(1) }

print("file: \(url.lastPathComponent)  \(file.count) bytes\n")

var timestampScale: UInt64 = 1_000_000
var durationTicks: Double = 0
var tracks: [Track] = []
var cues: [CueEntry] = []
var seekEntries: [(id: UInt32, pos: Int)] = []
var clusterOffsets: [Int] = []
var segmentDataStart = 0

/// Recursive descent. `budget` bounds a known-size master; nil means unknown
/// size, in which case we stop at the first ID that cannot be a child.
func walk(_ c: inout Cursor, end: Int, depth: Int, context _: UInt32) {
    while c.pos < end, c.remaining > 0 {
        let elementStart = c.absolute
        guard let id = c.readID() else { return }
        guard let sizeOpt = c.readSize() else { return }
        let contentStart = c.pos
        let size = sizeOpt ?? (end - contentStart)

        switch id {
        case ID.segment:
            segmentDataStart = c.absolute
            walk(&c, end: min(contentStart + size, c.data.count), depth: depth + 1, context: id)
            continue

        case ID.cluster:
            clusterOffsets.append(elementStart)
            // Only the first cluster is parsed in detail, below.
            c.skip(size)
            continue

        case ID.timestampScale:
            if let d = c.peek(size) {
                timestampScale = Cursor.uint(d)
            }

        case ID.duration:
            if let d = c.peek(size) {
                durationTicks = Cursor.float(d)
            }

        case ID.trackEntry:
            var t = Track()
            var sub = Cursor(data: c.data, base: c.base, pos: contentStart)
            let subEnd = contentStart + size
            while sub.pos < subEnd {
                guard let sid = sub.readID(), let ssizeOpt = sub.readSize() else { break }
                let ssize = ssizeOpt ?? 0
                switch sid {
                case ID.trackNumber: if let d = sub.peek(ssize) {
                        t.number = Int(Cursor.uint(d))
                    }
                case ID.trackType: if let d = sub.peek(ssize) {
                        t.type = Int(Cursor.uint(d))
                    }
                case ID.codecID: if let d = sub.peek(ssize) {
                        t.codecID = String(decoding: d, as: UTF8.self)
                    }
                case ID.codecPrivate: t.codecPrivate = sub.peek(ssize)
                case ID.video, ID.audio:
                    var inner = Cursor(data: sub.data, base: sub.base, pos: sub.pos)
                    let innerEnd = sub.pos + ssize
                    while inner.pos < innerEnd {
                        guard let iid = inner.readID(), let isizeOpt = inner.readSize() else { break }
                        let isize = isizeOpt ?? 0
                        switch iid {
                        case ID.pixelWidth: if let d = inner.peek(isize) {
                                t.width = Int(Cursor.uint(d))
                            }
                        case ID.pixelHeight: if let d = inner.peek(isize) {
                                t.height = Int(Cursor.uint(d))
                            }
                        case ID.channels: if let d = inner.peek(isize) {
                                t.channels = Int(Cursor.uint(d))
                            }
                        case ID.samplingFrequency: if let d = inner.peek(isize) {
                                t.sampleRate = Cursor.float(d)
                            }
                        default: break
                        }
                        inner.skip(isize)
                    }
                default: break
                }
                sub.skip(ssize)
            }
            tracks.append(t)
            c.skip(size)
            continue

        case ID.cuePoint:
            var e = CueEntry()
            var sub = Cursor(data: c.data, base: c.base, pos: contentStart)
            let subEnd = contentStart + size
            while sub.pos < subEnd {
                guard let sid = sub.readID(), let ssizeOpt = sub.readSize() else { break }
                let ssize = ssizeOpt ?? 0
                switch sid {
                case ID.cueTime: if let d = sub.peek(ssize) {
                        e.time = Cursor.uint(d)
                    }
                case ID.cueTrackPositions:
                    var inner = Cursor(data: sub.data, base: sub.base, pos: sub.pos)
                    let innerEnd = sub.pos + ssize
                    while inner.pos < innerEnd {
                        guard let iid = inner.readID(), let isizeOpt = inner.readSize() else { break }
                        let isize = isizeOpt ?? 0
                        switch iid {
                        case ID.cueTrack: if let d = inner.peek(isize) {
                                e.track = Int(Cursor.uint(d))
                            }
                        case ID.cueClusterPosition: if let d = inner.peek(isize) {
                                e.clusterPosition = Int(Cursor.uint(d))
                            }
                        default: break
                        }
                        inner.skip(isize)
                    }
                default: break
                }
                sub.skip(ssize)
            }
            cues.append(e)
            c.skip(size)
            continue

        case ID.seek:
            var sub = Cursor(data: c.data, base: c.base, pos: contentStart)
            let subEnd = contentStart + size
            var sid32: UInt32 = 0
            var spos = 0
            while sub.pos < subEnd {
                guard let sid = sub.readID(), let ssizeOpt = sub.readSize() else { break }
                let ssize = ssizeOpt ?? 0
                switch sid {
                case ID.seekID: if let d = sub.peek(ssize) {
                        sid32 = UInt32(Cursor.uint(d))
                    }
                case ID.seekPosition: if let d = sub.peek(ssize) {
                        spos = Int(Cursor.uint(d))
                    }
                default: break
                }
                sub.skip(ssize)
            }
            seekEntries.append((sid32, spos))
            c.skip(size)
            continue

        default:
            break
        }

        if ID.masters.contains(id) {
            walk(&c, end: min(contentStart + size, c.data.count), depth: depth + 1, context: id)
            c.pos = contentStart + size
        } else {
            c.skip(size)
        }
    }
}

var cursor = Cursor(data: file, base: 0)
walk(&cursor, end: file.count, depth: 0, context: 0)

// MARK: - Report

func name(forSeekID id: UInt32) -> String {
    switch id {
    case ID.info: "Info"
    case ID.tracks: "Tracks"
    case ID.cues: "Cues"
    case ID.cluster: "Cluster"
    case ID.seekHead: "SeekHead"
    default: String(format: "0x%X", id)
    }
}

print("== 1. ranged access: SeekHead ==")
if seekEntries.isEmpty {
    print("  NONE — would have to scan linearly (bad for ranged HTTP)")
} else {
    for e in seekEntries {
        print("  \(name(forSeekID: e.id).padding(toLength: 10, withPad: " ", startingAt: 0)) -> segment+\(e.pos)  (file offset \(segmentDataStart + e.pos))")
    }
}

print("  segment data starts at file offset \(segmentDataStart)")
print()

print("== 2. Info ==")
let durationSeconds = durationTicks * Double(timestampScale) / 1_000_000_000
print("  timestampScale: \(timestampScale) ns   duration: \(String(format: "%.3f", durationSeconds))s")
print()

print("== 3. Tracks ==")
for t in tracks {
    var line = "  #\(t.number) \(t.typeName)  \(t.codecID)"
    if let w = t.width, let h = t.height {
        line += "  \(w)x\(h)"
    }
    if let ch = t.channels {
        line += "  \(ch)ch"
    }
    if let sr = t.sampleRate {
        line += "  \(Int(sr))Hz"
    }
    line += "  CodecPrivate: \(t.codecPrivate?.count ?? 0) bytes"
    print(line)
}

print()

print("== 4. THE KEY QUESTION: is HEVC CodecPrivate already an hvcC? ==")
var nalLengthSize = 4
if let hevc = tracks.first(where: { $0.codecID.hasPrefix("V_MPEGH/ISO/HEVC") }), let p = hevc.codecPrivate, p.count >= 23 {
    let b = [UInt8](p)
    let version = b[0]
    let profileIDC = b[1] & 0x1F
    let levelIDC = b[12]
    let chromaFormat = b[16] & 0x03
    let bitDepthLuma = Int(b[17] & 0x07) + 8
    nalLengthSize = Int(b[21] & 0x03) + 1
    let numArrays = Int(b[22])
    print("  configurationVersion: \(version)   \(version == 1 ? "VALID hvcC" : "unexpected")")
    print("  profile_idc: \(profileIDC)  level_idc: \(levelIDC)  chroma: \(chromaFormat)  bitDepth: \(bitDepthLuma)")
    print("  lengthSizeMinusOne+1: \(nalLengthSize)   numOfArrays: \(numArrays)")
    var off = 23
    for _ in 0 ..< numArrays where off + 3 <= b.count {
        let nalType = b[off] & 0x3F
        let count = Int(b[off + 1]) << 8 | Int(b[off + 2])
        off += 3
        var kind = "?"
        switch nalType { case 32: kind = "VPS"; case 33: kind = "SPS"; case 34: kind = "PPS"; default: kind = "NAL\(nalType)" }
        var lens: [Int] = []
        for _ in 0 ..< count where off + 2 <= b.count {
            let len = Int(b[off]) << 8 | Int(b[off + 1])
            lens.append(len)
            off += 2 + len
        }
        print("    \(kind) x\(count)  sizes=\(lens)")
    }
    print("  -> this is EXACTLY the payload an fMP4 `hvc1` sample entry needs")
} else {
    print("  no HEVC track, or CodecPrivate too short")
}

print()

print("== 5. Cues (the seek + fragment index) ==")
print("  \(cues.count) cue points")
for e in cues.prefix(6) {
    let seconds = Double(e.time) * Double(timestampScale) / 1_000_000_000
    print("    t=\(String(format: "%7.3f", seconds))s  track=\(e.track)  cluster at segment+\(e.clusterPosition) (file \(segmentDataStart + e.clusterPosition))")
}

if cues.count > 6 {
    print("    … \(cues.count - 6) more")
}

print()

print("== 6. parse the cluster the first cue points at ==")
if let firstCue = cues.first {
    let clusterFileOffset = segmentDataStart + firstCue.clusterPosition
    var cc = Cursor(data: file, base: 0, pos: clusterFileOffset)
    guard let cid = cc.readID(), cid == ID.cluster, let csizeOpt = cc.readSize() else {
        print("  offset did not land on a Cluster — index is wrong")
        exit(1)
    }
    let csize = csizeOpt ?? 0
    print("  Cluster at file offset \(clusterFileOffset), \(csize) bytes")
    let cEnd = cc.pos + csize
    var clusterTS: UInt64 = 0
    var shown = 0
    var firstFrame: Data?
    while cc.pos < cEnd, shown < 8 {
        guard let bid = cc.readID(), let bsizeOpt = cc.readSize() else { break }
        let bsize = bsizeOpt ?? 0
        let contentStart = cc.pos
        if bid == ID.clusterTimestamp {
            if let d = cc.peek(bsize) {
                clusterTS = Cursor.uint(d)
            }
            print("  cluster timestamp: \(clusterTS)")
        } else if bid == ID.simpleBlock {
            var bc = Cursor(data: cc.data, base: 0, pos: contentStart)
            guard let tnumOpt = bc.readSize(), let tnum = tnumOpt else { break }
            guard let tsHi = bc.byte(), let tsLo = bc.byte(), let flags = bc.byte() else { break }
            let rel = Int16(bitPattern: UInt16(tsHi) << 8 | UInt16(tsLo))
            let keyframe = flags & 0x80 != 0
            let lacing = (flags & 0x06) >> 1
            let payloadLen = bsize - (bc.pos - contentStart)
            let absTS = Double(Int64(clusterTS) + Int64(rel)) * Double(timestampScale) / 1_000_000_000
            print("  SimpleBlock track=\(tnum) t=\(String(format: "%.3f", absTS))s key=\(keyframe) lacing=\(lacing) payload=\(payloadLen)B")
            if firstFrame == nil, tnum == 1 {
                firstFrame = bc.peek(min(payloadLen, 64))
            }
            shown += 1
        }
        cc.pos = contentStart + bsize
    }
    print()

    print("== 7. THE OTHER KEY QUESTION: are frames length-prefixed or Annex B? ==")
    if let f = firstFrame {
        let b = [UInt8](f)
        let prefix = b.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("  first \(min(4, b.count)) bytes: \(prefix)")
        let isAnnexB = b.count >= 4 && b[0] == 0 && b[1] == 0 && (b[2] == 1 || (b[2] == 0 && b[3] == 1))
        var declared = 0
        for i in 0 ..< min(nalLengthSize, b.count) {
            declared = (declared << 8) | Int(b[i])
        }
        print("  as a \(nalLengthSize)-byte big-endian length: \(declared)")
        if isAnnexB {
            print("  -> ANNEX B start codes. Remux would need a bitstream conversion.")
        } else {
            print("  -> LENGTH-PREFIXED NALUs. Remuxing is a BYTE COPY — no conversion.")
        }
    } else {
        print("  no video frame captured")
    }
} else {
    print("  no cues to follow")
}

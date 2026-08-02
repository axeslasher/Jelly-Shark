// Spike, part 2: validate the Matroska demuxer against a REAL mkvmerge-produced
// file, fetched entirely over HTTP Range — which is simultaneously a prototype
// of #176's access pattern.
//
// Part 1 proved the parser works on an ffmpeg-muxed synthetic fixture, but left
// four things unproven that real sources exercise:
//
//   - mkvmerge's output shape (all real library sources are mkvmerge)
//   - lacing (every synthetic block was lacing=0)
//   - BlockGroup vs SimpleBlock (B-frames with ReferenceBlock)
//   - scale (4 cue points vs thousands)
//
// It fetches only: the head, the Cues element, and one cluster. A few MB out of
// tens of GB. If that works, ranged demuxing is real.
//
// Usage:
//   SERVER=... KEY=... [ITEM=...] swift mkvdemux-ranged.swift
//
// Prints no URL and no key.

import Foundation

// MARK: - EBML primitives (identical to part 1, so results are comparable)

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

    mutating func readID() -> UInt32? {
        guard let first = peek(1)?.first else { return nil }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, w <= 4, let raw = take(w) else { return nil }
        return raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readSize() -> Int?? {
        guard let first = peek(1)?.first else { return .some(nil) }
        let w = EBML.width(ofFirstByte: first)
        guard w > 0, let raw = take(w) else { return .some(nil) }
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

enum ID {
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
    static let audio: UInt32 = 0xE1
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let channels: UInt32 = 0x9F
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cueRelativePosition: UInt32 = 0xF0
    static let cluster: UInt32 = 0x1F43_B675
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let referenceBlock: UInt32 = 0xFB
    // Dolby Vision profile 7 carries its enhancement layer here rather than in
    // the elementary stream, under BlockAddIDType 'hvcE' (0x68766345).
    static let blockAdditionMapping: UInt32 = 0x41E4
    static let blockAddIDValue: UInt32 = 0x41F0
    static let blockAddIDName: UInt32 = 0x41A4
    static let blockAddIDType: UInt32 = 0x41E7
    static let blockAddIDExtraData: UInt32 = 0x41ED
    static let blockAdditions: UInt32 = 0x75A1
    static let blockMore: UInt32 = 0xA6
    static let blockAddID: UInt32 = 0xEE
    static let blockAdditional: UInt32 = 0xA5
}

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    let s = String(bytes: b, encoding: .ascii) ?? ""
    return s.allSatisfy { $0.isASCII && !$0.isNewline && $0 != "\0" } ? s : String(format: "0x%X", v)
}

// MARK: - Ranged HTTP source

let env = ProcessInfo.processInfo.environment
guard let serverRaw = env["SERVER"], let key = env["KEY"] else {
    print("set SERVER and KEY"); exit(1)
}

let server = serverRaw.hasSuffix("/") ? String(serverRaw.dropLast()) : serverRaw
let item = env["ITEM"] ?? "9f857943fd7c4bff155b5e46c00460ed"
let urlString = "\(server)/Videos/\(item)/stream?static=true&mediaSourceId=\(item)&deviceId=mkvspike"
guard let sourceURL = URL(string: urlString) else { print("bad URL"); exit(1) }

var totalFetched = 0
var requestCount = 0

func fetch(_ start: Int, _ length: Int) -> Data? {
    var request = URLRequest(url: sourceURL)
    request.setValue(key, forHTTPHeaderField: "X-Emby-Token")
    request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
    let sem = DispatchSemaphore(value: 0)
    var out: Data?
    var status = 0
    // URLSession delivers on its own queue, so a plain semaphore wait is safe
    // here (unlike AVPlayerItem.status, which needs the main run loop).
    URLSession.shared.dataTask(with: request) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        out = data
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 60)
    guard status == 206 || status == 200, let d = out else {
        print("  fetch \(start)+\(length) failed (HTTP \(status))")
        return nil
    }
    requestCount += 1
    totalFetched += d.count
    return d
}

/// Read an element header at an absolute offset, returning its ID, the offset
/// its content starts at, and the content length.
func elementHeader(at offset: Int) -> (id: UInt32, contentStart: Int, size: Int)? {
    guard let probe = fetch(offset, 16) else { return nil }
    var c = Cursor(data: probe, base: offset)
    guard let id = c.readID(), let sizeOpt = c.readSize(), let size = sizeOpt else { return nil }
    return (id, offset + c.pos, size)
}

print("=== ranged Matroska demux against a live source ===\n")

// MARK: - 1. head

print("== 1. head: EBML + SeekHead + Info + Tracks ==")
guard let head = fetch(0, 96 * 1024) else { exit(1) }
print("  fetched \(head.count) bytes")

var segmentDataStart = 0
var seekEntries: [(id: UInt32, pos: Int)] = []
var timestampScale: UInt64 = 1_000_000
var durationTicks: Double = 0

struct Track {
    var number = 0, type = 0
    var codecID = ""
    var codecPrivate: Data?
    var width: Int?, height: Int?, channels: Int?
    /// BlockAdditionMapping entries — where DV profile 7's enhancement layer is
    /// declared (`BlockAddIDType == 'hvcE'`), with a `dvcC`/`dvvC` in extra data.
    var addMappings: [(type: UInt32, value: UInt64, extra: Data?)] = []
}

var tracks: [Track] = []

func parseTrackEntry(_ data: Data, _ start: Int, _ size: Int, base: Int) -> Track {
    var t = Track()
    var sub = Cursor(data: data, base: base, pos: start)
    let end = start + size
    while sub.pos < end {
        guard let sid = sub.readID(), let ssOpt = sub.readSize(), let ss = ssOpt else { break }
        switch sid {
        case ID.trackNumber: if let d = sub.peek(ss) {
                t.number = Int(Cursor.uint(d))
            }
        case ID.trackType: if let d = sub.peek(ss) {
                t.type = Int(Cursor.uint(d))
            }
        case ID.codecID: if let d = sub.peek(ss) {
                t.codecID = String(decoding: d, as: UTF8.self)
            }
        case ID.codecPrivate: t.codecPrivate = sub.peek(ss)
        case ID.blockAdditionMapping:
            var m = (type: UInt32(0), value: UInt64(0), extra: Data?.none)
            var inner = Cursor(data: sub.data, base: base, pos: sub.pos)
            let mEnd = sub.pos + ss
            while inner.pos < mEnd {
                guard let mid = inner.readID(), let msOpt = inner.readSize(), let ms = msOpt else { break }
                switch mid {
                case ID.blockAddIDType: if let d = inner.peek(ms) {
                        m.type = UInt32(Cursor.uint(d))
                    }
                case ID.blockAddIDValue: if let d = inner.peek(ms) {
                        m.value = Cursor.uint(d)
                    }
                case ID.blockAddIDExtraData: m.extra = inner.peek(ms)
                default: break
                }
                inner.skip(ms)
            }
            t.addMappings.append(m)
        case ID.video, ID.audio:
            var inner = Cursor(data: sub.data, base: base, pos: sub.pos)
            let iEnd = sub.pos + ss
            while inner.pos < iEnd {
                guard let iid = inner.readID(), let isOpt = inner.readSize(), let isz = isOpt else { break }
                switch iid {
                case ID.pixelWidth: if let d = inner.peek(isz) {
                        t.width = Int(Cursor.uint(d))
                    }
                case ID.pixelHeight: if let d = inner.peek(isz) {
                        t.height = Int(Cursor.uint(d))
                    }
                case ID.channels: if let d = inner.peek(isz) {
                        t.channels = Int(Cursor.uint(d))
                    }
                default: break
                }
                inner.skip(isz)
            }
        default: break
        }
        sub.skip(ss)
    }
    return t
}

func walkHead(_ c: inout Cursor, end: Int) {
    while c.pos < end, c.remaining > 0 {
        guard let id = c.readID(), let sizeOpt = c.readSize() else { return }
        let contentStart = c.pos
        let size = sizeOpt ?? (end - contentStart)
        switch id {
        case ID.segment:
            segmentDataStart = c.absolute
            walkHead(&c, end: min(contentStart + size, c.data.count))
            return
        case ID.seekHead, ID.info, ID.tracks:
            walkHead(&c, end: min(contentStart + size, c.data.count))
            c.pos = min(contentStart + size, c.data.count)
            continue
        case ID.seek:
            var sub = Cursor(data: c.data, base: c.base, pos: contentStart)
            var sid32: UInt32 = 0
            var spos = 0
            let subEnd = contentStart + size
            while sub.pos < subEnd {
                guard let s = sub.readID(), let szOpt = sub.readSize(), let sz = szOpt else { break }
                if s == ID.seekID, let d = sub.peek(sz) {
                    sid32 = UInt32(Cursor.uint(d))
                }
                if s == ID.seekPosition, let d = sub.peek(sz) {
                    spos = Int(Cursor.uint(d))
                }
                sub.skip(sz)
            }
            seekEntries.append((sid32, spos))
        case ID.timestampScale: if let d = c.peek(size) {
                timestampScale = Cursor.uint(d)
            }
        case ID.duration: if let d = c.peek(size) {
                durationTicks = Cursor.float(d)
            }
        case ID.trackEntry:
            tracks.append(parseTrackEntry(c.data, contentStart, size, base: c.base))
        default: break
        }
        c.pos = min(contentStart + size, c.data.count)
    }
}

var headCursor = Cursor(data: head, base: 0)
walkHead(&headCursor, end: head.count)

func seekName(_ id: UInt32) -> String {
    switch id {
    case ID.info: "Info"
    case ID.tracks: "Tracks"
    case ID.cues: "Cues"
    case ID.cluster: "Cluster"
    case ID.seekHead: "SeekHead"
    default: String(format: "0x%X", id)
    }
}

print("  segment data starts at \(segmentDataStart)")
for e in seekEntries {
    print("    \(seekName(e.id).padding(toLength: 9, withPad: " ", startingAt: 0)) -> segment+\(e.pos)")
}

print("  timestampScale \(timestampScale)ns   duration \(String(format: "%.1f", durationTicks * Double(timestampScale) / 1e9))s")
for t in tracks {
    var l = "    #\(t.number) type=\(t.type) \(t.codecID)"
    if let w = t.width, let h = t.height {
        l += " \(w)x\(h)"
    }
    if let ch = t.channels {
        l += " \(ch)ch"
    }
    l += " CodecPrivate=\(t.codecPrivate?.count ?? 0)B"
    print(l)
    for m in t.addMappings {
        var detail = "      BlockAdditionMapping type=\(fourCC(m.type)) value=\(m.value) extra=\(m.extra?.count ?? 0)B"
        // 'hvcE' declares a Dolby Vision enhancement layer; its extra data is a
        // dvcC/dvvC box, i.e. exactly the DV config an fMP4 needs.
        if let e = m.extra, e.count >= 8 {
            let b = [UInt8](e)
            let boxName = String(bytes: b[4 ..< 8], encoding: .ascii) ?? "?"
            detail += "  (box: \(boxName))"
        }
        print(detail)
    }
}

if let hevc = tracks.first(where: { $0.codecID.hasPrefix("V_MPEGH/ISO/HEVC") }), let p = hevc.codecPrivate, p.count >= 23 {
    let b = [UInt8](p)
    print("  hvcC: version=\(b[0]) profile=\(b[1] & 0x1F) level=\(b[12]) bitDepth=\(Int(b[17] & 0x07) + 8) nalLen=\(Int(b[21] & 0x03) + 1) arrays=\(b[22])")
}

print()

// MARK: - 2. Cues

print("== 2. Cues, range-fetched at the SeekHead offset ==")
struct CueEntry { var time: UInt64 = 0; var track = 0; var clusterPosition = 0; var relative: Int? }
var cues: [CueEntry] = []

guard let cueSeek = seekEntries.first(where: { $0.id == ID.cues }) else {
    print("  no Cues in SeekHead — file may be unseekable; would need to refuse to the server path")
    exit(1)
}

let cuesOffset = segmentDataStart + cueSeek.pos
guard let ch = elementHeader(at: cuesOffset), ch.id == ID.cues else {
    print("  SeekHead offset did not land on Cues")
    exit(1)
}

print("  Cues element: \(ch.size) bytes at file offset \(cuesOffset)")
guard let cuesData = fetch(ch.contentStart, ch.size) else { exit(1) }

var cc = Cursor(data: cuesData, base: ch.contentStart)
var sawRelative = 0
while cc.remaining > 0 {
    guard let id = cc.readID(), let szOpt = cc.readSize(), let sz = szOpt else { break }
    let start = cc.pos
    if id == ID.cuePoint {
        var e = CueEntry()
        var sub = Cursor(data: cc.data, base: cc.base, pos: start)
        let end = start + sz
        while sub.pos < end {
            guard let sid = sub.readID(), let ssOpt = sub.readSize(), let ss = ssOpt else { break }
            if sid == ID.cueTime, let d = sub.peek(ss) {
                e.time = Cursor.uint(d)
            }
            if sid == ID.cueTrackPositions {
                var inner = Cursor(data: sub.data, base: sub.base, pos: sub.pos)
                let iEnd = sub.pos + ss
                while inner.pos < iEnd {
                    guard let iid = inner.readID(), let isOpt = inner.readSize(), let isz = isOpt else { break }
                    if iid == ID.cueTrack, let d = inner.peek(isz) {
                        e.track = Int(Cursor.uint(d))
                    }
                    if iid == ID.cueClusterPosition, let d = inner.peek(isz) {
                        e.clusterPosition = Int(Cursor.uint(d))
                    }
                    if iid == ID.cueRelativePosition, let d = inner.peek(isz) {
                        e.relative = Int(Cursor.uint(d)); sawRelative += 1
                    }
                    inner.skip(isz)
                }
            }
            sub.skip(ss)
        }
        cues.append(e)
    }
    cc.pos = start + sz
}

print("  parsed \(cues.count) cue points   (CueRelativePosition present on \(sawRelative))")
for e in cues.prefix(3) {
    print("    t=\(String(format: "%8.3f", Double(e.time) * Double(timestampScale) / 1e9))s track=\(e.track) cluster=segment+\(e.clusterPosition)")
}

if cues.count > 3 {
    let last = cues[cues.count - 1]
    print("    … last: t=\(String(format: "%.1f", Double(last.time) * Double(timestampScale) / 1e9))s cluster=segment+\(last.clusterPosition)")
}

print()

// MARK: - 3. a cluster from the middle

print("== 3. a cluster from the middle of the film, range-fetched ==")
let midCue = cues[cues.count / 2]
let clusterOffset = segmentDataStart + midCue.clusterPosition
guard let clh = elementHeader(at: clusterOffset), clh.id == ID.cluster else {
    print("  cue offset did not land on a Cluster — index unusable")
    exit(1)
}

let clusterBytes = min(clh.size, 16 * 1024 * 1024)
print("  Cluster \(clh.size) bytes at \(clusterOffset); fetching \(clusterBytes)")
guard let clusterData = fetch(clh.contentStart, clusterBytes) else { exit(1) }

var blockAdditionCounts: [UInt64: Int] = [:]
var blockAdditionBytes: [UInt64: Int] = [:]
var simpleBlocks = 0, blockGroups = 0
var lacingCounts: [Int: Int] = [:]
var perTrack: [Int: Int] = [:]
var keyframes = 0
var firstVideoFrame: Data?
var clusterTS: UInt64 = 0
var bc = Cursor(data: clusterData, base: clh.contentStart)

func parseBlockPayload(_ c: inout Cursor, size: Int, isSimple: Bool) {
    let start = c.pos
    guard let tnOpt = c.readSize(), let tn = tnOpt,
          let hi = c.byte(), let lo = c.byte(), let flags = c.byte() else { return }
    _ = Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo))
    let lacing = Int((flags & 0x06) >> 1)
    lacingCounts[lacing, default: 0] += 1
    perTrack[tn, default: 0] += 1
    if isSimple, flags & 0x80 != 0 {
        keyframes += 1
    }
    let payloadLen = size - (c.pos - start)
    if firstVideoFrame == nil, tn == 1 {
        firstVideoFrame = c.peek(min(payloadLen, 32))
    }
}

while bc.remaining > 0 {
    guard let id = bc.readID(), let szOpt = bc.readSize(), let sz = szOpt else { break }
    let start = bc.pos
    if id == ID.clusterTimestamp, let d = bc.peek(sz) {
        clusterTS = Cursor.uint(d)
    } else if id == ID.simpleBlock {
        simpleBlocks += 1
        var sub = Cursor(data: bc.data, base: bc.base, pos: start)
        parseBlockPayload(&sub, size: sz, isSimple: true)
    } else if id == ID.blockGroup {
        blockGroups += 1
        var sub = Cursor(data: bc.data, base: bc.base, pos: start)
        let end = start + sz
        var hasReference = false
        while sub.pos < end {
            guard let gid = sub.readID(), let gsOpt = sub.readSize(), let gs = gsOpt else { break }
            if gid == ID.block {
                var inner = Cursor(data: sub.data, base: sub.base, pos: sub.pos)
                parseBlockPayload(&inner, size: gs, isSimple: false)
            }
            if gid == ID.referenceBlock {
                hasReference = true
            }
            if gid == ID.blockAdditions {
                // DV profile 7's enhancement layer lives here, keyed by
                // BlockAddID matching a BlockAdditionMapping's value.
                var add = Cursor(data: sub.data, base: sub.base, pos: sub.pos)
                let aEnd = sub.pos + gs
                while add.pos < aEnd {
                    guard let aid = add.readID(), let asOpt = add.readSize(), let asz = asOpt else { break }
                    if aid == ID.blockMore {
                        var more = Cursor(data: add.data, base: add.base, pos: add.pos)
                        let mEnd = add.pos + asz
                        var addID: UInt64 = 1
                        var payload = 0
                        while more.pos < mEnd {
                            guard let mid = more.readID(), let msOpt = more.readSize(), let ms = msOpt else { break }
                            if mid == ID.blockAddID, let d = more.peek(ms) {
                                addID = Cursor.uint(d)
                            }
                            if mid == ID.blockAdditional {
                                payload = ms
                            }
                            more.skip(ms)
                        }
                        blockAdditionCounts[addID, default: 0] += 1
                        blockAdditionBytes[addID, default: 0] += payload
                    }
                    add.skip(asz)
                }
            }
            sub.skip(gs)
        }
        if !hasReference {
            keyframes += 1
        }
    }
    bc.pos = start + sz
}

print("  cluster timestamp: \(String(format: "%.3f", Double(clusterTS) * Double(timestampScale) / 1e9))s")
print("  SimpleBlock: \(simpleBlocks)   BlockGroup: \(blockGroups)   keyframes: \(keyframes)")
print("  blocks per track: \(perTrack.sorted { $0.key < $1.key }.map { "#\($0.key)=\($0.value)" }.joined(separator: " "))")
let lacingNames = [0: "none", 1: "Xiph", 2: "fixed", 3: "EBML"]
print("  lacing: \(lacingCounts.sorted { $0.key < $1.key }.map { "\(lacingNames[$0.key] ?? "?")=\($0.value)" }.joined(separator: " "))")
if blockAdditionCounts.isEmpty {
    print("  BlockAdditions: none — no DV enhancement layer in this cluster")
} else {
    for (addID, count) in blockAdditionCounts.sorted(by: { $0.key < $1.key }) {
        let bytes = blockAdditionBytes[addID] ?? 0
        print("  BlockAdditions: addID=\(addID) x\(count), \(bytes) bytes of payload")
    }
    print("  -> this is the Dolby Vision enhancement layer riding alongside the base layer")
}

if let f = firstVideoFrame {
    let b = [UInt8](f)
    let hex = b.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
    let annexB = b.count >= 4 && b[0] == 0 && b[1] == 0 && (b[2] == 1 || (b[2] == 0 && b[3] == 1))
    var declared = 0
    for i in 0 ..< min(4, b.count) {
        declared = (declared << 8) | Int(b[i])
    }
    print("  first video frame bytes: \(hex)  -> \(annexB ? "ANNEX B (needs conversion)" : "length-prefixed, len=\(declared) (byte copy)")")
}

print()

print("== cost ==")
print("  \(requestCount) ranged requests, \(totalFetched) bytes fetched")
print("  (the source file is tens of GB)")

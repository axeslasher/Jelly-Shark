// Targeted probe: where does Dolby Vision profile 7's ENHANCEMENT LAYER live?
//
// The ranged spike found the track declares two BlockAdditionMappings —
// `dvcC` (24B, a DOVIDecoderConfigurationRecord) and `hvcE` (172B) — but the one
// sampled cluster had zero BlockGroups and zero BlockAdditions. SimpleBlock
// cannot carry BlockAdditions, so that sample could not have shown an EL even if
// one were there.
//
// Three hypotheses, and this discriminates them:
//
//   A. EL rides in BlockAdditions  -> scan many clusters, expect BlockGroups
//   B. EL is in-band in the video stream -> NALUs with nuh_layer_id == 1
//   C. Mapping declared but unused  -> neither appears anywhere
//
// It also parses the `hvcE` extra data as an hvcC, since for a separately-carried
// EL that should be the EL's own decoder configuration.
//
// Usage:
//   SERVER=... KEY=... ITEM=c0dbc3c5b4a316fe2d8390f12cbe3be6 \
//     swift mkvdemux-el-probe.swift

import Foundation

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
    var remaining: Int {
        data.count - pos
    }

    var absolute: Int {
        base + pos
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
}

enum ID {
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549_A966
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let blockAdditionMapping: UInt32 = 0x41E4
    static let blockAddIDType: UInt32 = 0x41E7
    static let blockAddIDExtraData: UInt32 = 0x41ED
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cluster: UInt32 = 0x1F43_B675
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockAdditions: UInt32 = 0x75A1
    static let blockMore: UInt32 = 0xA6
    static let blockAddID: UInt32 = 0xEE
    static let blockAdditional: UInt32 = 0xA5
}

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    if b.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return String(bytes: b, encoding: .ascii) ?? "?"
    }
    return String(format: "0x%08X", v)
}

/// HEVC NAL unit types we care about naming.
func nalName(_ t: Int) -> String {
    switch t {
    case 0 ... 9: "slice(\(t))"
    case 16 ... 21: "IRAP(\(t))"
    case 32: "VPS"
    case 33: "SPS"
    case 34: "PPS"
    case 35: "AUD"
    case 39: "PREFIX_SEI"
    case 40: "SUFFIX_SEI"
    case 62: "UNSPEC62 (Dolby Vision RPU)"
    case 63: "UNSPEC63 (Dolby Vision EL)"
    default: "NAL\(t)"
    }
}

// MARK: - HTTP

let env = ProcessInfo.processInfo.environment
guard let serverRaw = env["SERVER"], let key = env["KEY"] else { print("set SERVER and KEY"); exit(1) }
let server = serverRaw.hasSuffix("/") ? String(serverRaw.dropLast()) : serverRaw
let item = env["ITEM"] ?? "c0dbc3c5b4a316fe2d8390f12cbe3be6"
let clustersToSample = Int(env["CLUSTERS"] ?? "10") ?? 10
guard let sourceURL = URL(string: "\(server)/Videos/\(item)/stream?static=true&mediaSourceId=\(item)&deviceId=elprobe") else {
    print("bad URL"); exit(1)
}

var totalFetched = 0
var requests = 0

func fetch(_ start: Int, _ length: Int) -> Data? {
    var r = URLRequest(url: sourceURL)
    r.setValue(key, forHTTPHeaderField: "X-Emby-Token")
    r.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
    let sem = DispatchSemaphore(value: 0)
    var out: Data?
    var status = 0
    URLSession.shared.dataTask(with: r) { d, resp, _ in
        status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        out = d
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 120)
    guard status == 206 || status == 200, let d = out else { return nil }
    requests += 1
    totalFetched += d.count
    return d
}

func elementHeader(at offset: Int) -> (id: UInt32, contentStart: Int, size: Int)? {
    guard let probe = fetch(offset, 16) else { return nil }
    var c = Cursor(data: probe, base: offset)
    guard let id = c.readID(), let sOpt = c.readSize(), let s = sOpt else { return nil }
    return (id, offset + c.pos, s)
}

// MARK: - head

print("=== Dolby Vision enhancement-layer probe ===\n")

guard let head = fetch(0, 128 * 1024) else { print("head fetch failed"); exit(1) }
var segmentDataStart = 0
var seekEntries: [(id: UInt32, pos: Int)] = []
var videoTrackNumber = 1
var hvcEExtra: Data?
var dvcCExtra: Data?
var nalLengthSize = 4

func walkHead(_ c: inout Cursor, end: Int) {
    while c.pos < end, c.remaining > 0 {
        guard let id = c.readID(), let sOpt = c.readSize() else { return }
        let contentStart = c.pos
        let size = sOpt ?? (end - contentStart)
        switch id {
        case ID.segment:
            segmentDataStart = c.absolute
            walkHead(&c, end: min(contentStart + size, c.data.count))
            return
        case ID.seekHead, ID.tracks, ID.info:
            walkHead(&c, end: min(contentStart + size, c.data.count))
            c.pos = min(contentStart + size, c.data.count)
            continue
        case ID.seek:
            var s = Cursor(data: c.data, base: c.base, pos: contentStart)
            var sid: UInt32 = 0
            var spos = 0
            let e = contentStart + size
            while s.pos < e {
                guard let i = s.readID(), let zOpt = s.readSize(), let z = zOpt else { break }
                if i == ID.seekID, let d = s.peek(z) {
                    sid = UInt32(Cursor.uint(d))
                }
                if i == ID.seekPosition, let d = s.peek(z) {
                    spos = Int(Cursor.uint(d))
                }
                s.skip(z)
            }
            seekEntries.append((sid, spos))
        case ID.trackEntry:
            var s = Cursor(data: c.data, base: c.base, pos: contentStart)
            let e = contentStart + size
            var num = 0
            var type = 0
            var isHEVC = false
            var trackCodecPrivate: Data?
            while s.pos < e {
                guard let i = s.readID(), let zOpt = s.readSize(), let z = zOpt else { break }
                switch i {
                case ID.trackNumber: if let d = s.peek(z) {
                        num = Int(Cursor.uint(d))
                    }
                case ID.trackType: if let d = s.peek(z) {
                        type = Int(Cursor.uint(d))
                    }
                case ID.codecID: if let d = s.peek(z) {
                        isHEVC = String(decoding: d, as: UTF8.self).hasPrefix("V_MPEGH/ISO/HEVC")
                    }
                case ID.codecPrivate:
                    // Hold it locally: TrackEntry children have no guaranteed
                    // order, so isHEVC may not be known yet. Applying this
                    // eagerly let a FLAC track's CodecPrivate clobber the HEVC
                    // NAL length prefix with a nonsense value of 1.
                    trackCodecPrivate = s.peek(z)
                case ID.blockAdditionMapping:
                    var m = Cursor(data: s.data, base: s.base, pos: s.pos)
                    let me = s.pos + z
                    var mtype: UInt32 = 0
                    var extra: Data?
                    while m.pos < me {
                        guard let mi = m.readID(), let mzOpt = m.readSize(), let mz = mzOpt else { break }
                        if mi == ID.blockAddIDType, let d = m.peek(mz) {
                            mtype = UInt32(Cursor.uint(d))
                        }
                        if mi == ID.blockAddIDExtraData {
                            extra = m.peek(mz)
                        }
                        m.skip(mz)
                    }
                    if fourCC(mtype) == "hvcE" {
                        hvcEExtra = extra
                    }
                    if fourCC(mtype) == "dvcC" || fourCC(mtype) == "dvvC" {
                        dvcCExtra = extra
                    }
                default: break
                }
                s.skip(z)
            }
            if type == 1, isHEVC {
                videoTrackNumber = num
                // Only the HEVC track's CodecPrivate is an hvcC, so only it may
                // define the NAL length prefix.
                if let d = trackCodecPrivate, d.count >= 23 {
                    nalLengthSize = Int([UInt8](d)[21] & 0x03) + 1
                }
            }
        default: break
        }
        c.pos = min(contentStart + size, c.data.count)
    }
}

var hc = Cursor(data: head, base: 0)
walkHead(&hc, end: head.count)
print("video track: #\(videoTrackNumber)   NAL length prefix: \(nalLengthSize) bytes\n")

// MARK: - 1. the mapping payloads

print("== 1. what the BlockAdditionMapping extra data actually is ==")
if let d = dvcCExtra {
    let b = [UInt8](d)
    print("  dvcC extra: \(b.count) bytes")
    if b.count >= 5 {
        let major = b[0], minor = b[1]
        let profile = (b[2] >> 1) & 0x7F
        let level = ((b[2] & 0x01) << 5) | ((b[3] >> 3) & 0x1F)
        let rpu = (b[3] >> 2) & 0x01, el = (b[3] >> 1) & 0x01, bl = b[3] & 0x01
        let compat = (b[4] >> 4) & 0x0F
        print("    DOVIDecoderConfigurationRecord: v\(major).\(minor) profile=\(profile) level=\(level)")
        print("    rpu=\(rpu) el=\(el) bl=\(bl) blCompatId=\(compat)")
        print("    -> ready to write straight into an fMP4 dvcC box")
    }
} else {
    print("  no dvcC mapping")
}

if let d = hvcEExtra {
    let b = [UInt8](d)
    print("  hvcE extra: \(b.count) bytes")
    if b.count >= 23, b[0] == 1 {
        print("    parses as an hvcC: version=\(b[0]) profile=\(b[1] & 0x1F) level=\(b[12]) numArrays=\(b[22])")
        print("    -> the ENHANCEMENT LAYER has its own decoder config, i.e. it is a SEPARATE stream")
    } else {
        print("    does not look like an hvcC (first byte \(b.first.map { String($0) } ?? "-"))")
    }
} else {
    print("  no hvcE mapping")
}

print()

// MARK: - Cues

guard let cueSeek = seekEntries.first(where: { $0.id == ID.cues }),
      let ch = elementHeader(at: segmentDataStart + cueSeek.pos), ch.id == ID.cues,
      let cuesData = fetch(ch.contentStart, ch.size)
else { print("could not read Cues"); exit(1) }

var cuePositions: [Int] = []
var cc = Cursor(data: cuesData, base: ch.contentStart)
while cc.remaining > 0 {
    guard let id = cc.readID(), let zOpt = cc.readSize(), let z = zOpt else { break }
    let start = cc.pos
    if id == ID.cuePoint {
        var s = Cursor(data: cc.data, base: cc.base, pos: start)
        let e = start + z
        var pos = 0
        while s.pos < e {
            guard let i = s.readID(), let szOpt = s.readSize(), let sz = szOpt else { break }
            if i == ID.cueTrackPositions {
                var inner = Cursor(data: s.data, base: s.base, pos: s.pos)
                let ie = s.pos + sz
                while inner.pos < ie {
                    guard let ii = inner.readID(), let izOpt = inner.readSize(), let iz = izOpt else { break }
                    if ii == ID.cueClusterPosition, let d = inner.peek(iz) {
                        pos = Int(Cursor.uint(d))
                    }
                    inner.skip(iz)
                }
            }
            s.skip(sz)
        }
        if pos > 0 {
            cuePositions.append(pos)
        }
    }
    cc.pos = start + z
}

print("== 2. sampling \(clustersToSample) clusters spread across \(cuePositions.count) cue points ==")

// MARK: - scan clusters

var totalBlockGroups = 0
var totalSimpleBlocks = 0
var additionCounts: [UInt64: Int] = [:]
var additionBytes: [UInt64: Int] = [:]
var nalHistogram: [String: Int] = [:]
var nalBytes: [String: Int] = [:]
var layerHistogram: [Int: Int] = [:]
var videoFramesScanned = 0

/// Walk the length-prefixed NALUs inside one video frame, recording HEVC
/// nal_unit_type and nuh_layer_id. Layer 1 == a dual-layer enhancement layer
/// carried in-band; type 62 == the Dolby Vision RPU.
func scanNALUs(_ frame: Data) {
    var i = 0
    let b = [UInt8](frame)
    while i + nalLengthSize + 2 <= b.count {
        var len = 0
        for k in 0 ..< nalLengthSize {
            len = (len << 8) | Int(b[i + k])
        }
        i += nalLengthSize
        guard len > 1, i + 2 <= b.count else { break }
        let b0 = b[i], b1 = b[i + 1]
        let type = Int((b0 >> 1) & 0x3F)
        let layer = Int(((b0 & 0x01) << 5) | ((b1 >> 3) & 0x1F))
        nalHistogram[nalName(type), default: 0] += 1
        nalBytes[nalName(type), default: 0] += len
        layerHistogram[layer, default: 0] += 1
        i += len
    }
}

let step = max(1, cuePositions.count / clustersToSample)
var sampled = 0
for idx in stride(from: 0, to: cuePositions.count, by: step) {
    if sampled >= clustersToSample {
        break
    }
    let offset = segmentDataStart + cuePositions[idx]
    guard let clh = elementHeader(at: offset), clh.id == ID.cluster else { continue }
    let want = min(clh.size, 8 * 1024 * 1024)
    guard let cd = fetch(clh.contentStart, want) else { continue }
    sampled += 1

    var c = Cursor(data: cd, base: clh.contentStart)
    while c.remaining > 0 {
        guard let id = c.readID(), let zOpt = c.readSize(), let z = zOpt else { break }
        let start = c.pos
        if id == ID.simpleBlock {
            totalSimpleBlocks += 1
            var s = Cursor(data: c.data, base: c.base, pos: start)
            if let tnOpt = s.readSize(), let tn = tnOpt,
               s.byte() != nil, s.byte() != nil, s.byte() != nil
            {
                if tn == UInt64(videoTrackNumber), videoFramesScanned < 40 {
                    let payloadLen = z - (s.pos - start)
                    if let frame = s.peek(min(payloadLen, 2 * 1024 * 1024)) {
                        scanNALUs(frame)
                        videoFramesScanned += 1
                    }
                }
            }
        } else if id == ID.blockGroup {
            totalBlockGroups += 1
            var s = Cursor(data: c.data, base: c.base, pos: start)
            let e = start + z
            while s.pos < e {
                guard let gid = s.readID(), let gzOpt = s.readSize(), let gz = gzOpt else { break }
                if gid == ID.block {
                    var inner = Cursor(data: s.data, base: s.base, pos: s.pos)
                    if let tnOpt = inner.readSize(), let tn = tnOpt,
                       inner.byte() != nil, inner.byte() != nil, inner.byte() != nil
                    {
                        if tn == UInt64(videoTrackNumber), videoFramesScanned < 40 {
                            let payloadLen = gz - (inner.pos - s.pos)
                            if let frame = inner.peek(min(payloadLen, 2 * 1024 * 1024)) {
                                scanNALUs(frame)
                                videoFramesScanned += 1
                            }
                        }
                    }
                }
                if gid == ID.blockAdditions {
                    var add = Cursor(data: s.data, base: s.base, pos: s.pos)
                    let ae = s.pos + gz
                    while add.pos < ae {
                        guard let aid = add.readID(), let azOpt = add.readSize(), let az = azOpt else { break }
                        if aid == ID.blockMore {
                            var m = Cursor(data: add.data, base: add.base, pos: add.pos)
                            let me = add.pos + az
                            var addID: UInt64 = 1
                            var payload = 0
                            while m.pos < me {
                                guard let mi = m.readID(), let mzOpt = m.readSize(), let mz = mzOpt else { break }
                                if mi == ID.blockAddID, let d = m.peek(mz) {
                                    addID = Cursor.uint(d)
                                }
                                if mi == ID.blockAdditional {
                                    payload = mz
                                }
                                m.skip(mz)
                            }
                            additionCounts[addID, default: 0] += 1
                            additionBytes[addID, default: 0] += payload
                        }
                        add.skip(az)
                    }
                }
                s.skip(gz)
            }
        }
        c.pos = start + z
    }
}

print("  sampled \(sampled) clusters")
print("  SimpleBlock: \(totalSimpleBlocks)   BlockGroup: \(totalBlockGroups)")
print()

print("== 3. HYPOTHESIS A — EL in BlockAdditions ==")
if additionCounts.isEmpty {
    print("  NO BlockAdditions found in any sampled cluster")
} else {
    for (k, v) in additionCounts.sorted(by: { $0.key < $1.key }) {
        print("  addID=\(k): \(v) additions, \(additionBytes[k] ?? 0) bytes")
    }
}

print()

print("== 4. HYPOTHESIS B — EL in-band in the video stream ==")
print("  scanned \(videoFramesScanned) video frames")
print("  nuh_layer_id histogram: \(layerHistogram.sorted { $0.key < $1.key }.map { "layer\($0.key)=\($0.value)" }.joined(separator: " "))")
let allNalBytes = nalBytes.values.reduce(0, +)
for (k, v) in nalHistogram.sorted(by: { $0.value > $1.value }) {
    let bytes = nalBytes[k] ?? 0
    let share = allNalBytes > 0 ? Double(bytes) * 100 / Double(allNalBytes) : 0
    let label = k.padding(toLength: 28, withPad: " ", startingAt: 0)
    print("    \(label) \(v) NALUs  \(bytes) B  \(String(format: "%.1f", share))%")
}

print("    total \(allNalBytes) B across \(videoFramesScanned) frames")

print()

print("== verdict ==")
let hasLayer1 = (layerHistogram[1] ?? 0) > 0
let hasRPU = (nalHistogram.first { $0.key.hasPrefix("UNSPEC62") }?.value ?? 0) > 0
// Single-track dual-layer P7 remaps the EL to UNSPEC63 at layer 0 rather than
// using nuh_layer_id — testing only for layer 1 misses it entirely, which is
// exactly what the first run of this probe got wrong.
let elNALs = nalHistogram.first { $0.key.hasPrefix("UNSPEC63") }?.value ?? 0
let elBytes = nalBytes.first { $0.key.hasPrefix("UNSPEC63") }?.value ?? 0
let hasAdditions = !additionCounts.isEmpty

if hasAdditions {
    print("  A: EL rides in BlockAdditions — a remuxer must carry or drop it deliberately.")
} else if elNALs > 0 || hasLayer1 {
    let form = hasLayer1 ? "nuh_layer_id=1 (cross-track dual-layer)" : "UNSPEC63 at layer 0 (single-track dual-layer)"
    print("  B: EL is IN-BAND as \(form).")
    print("     \(elNALs) EL NALUs, \(elBytes) bytes — \(String(format: "%.1f", allNalBytes > 0 ? Double(elBytes) * 100 / Double(allNalBytes) : 0))% of video payload.")
    print()
    print("     Apple does NOT decode profile 7. The conversion is to DROP the EL NALUs,")
    print("     keep the base slices + UNSPEC62 RPU, and author a dvcC declaring profile 8.1.")
    print("     That is a filter in the copy loop — no decode, no re-encode, and it")
    print("     removes the bytes above from the delivered stream.")
} else if hasRPU {
    print("  C: RPU present, no EL — already single-layer. Copy base layer + dvcC as-is.")
} else {
    print("  Neither EL nor RPU seen in the sampled frames — widen the sample (CLUSTERS=20).")
}

print()
print("cost: \(requests) requests, \(totalFetched) bytes")

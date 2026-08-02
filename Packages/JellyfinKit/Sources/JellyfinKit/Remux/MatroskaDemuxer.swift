import Foundation

// Read-only Matroska demuxer (#176). Pure logic over an abstract byte source,
// so the same code runs against an in-memory fixture (tests), a local file, or
// Jellyfin's `static=true` endpoint over HTTP `Range` — verified to serve
// 206 + Content-Range (see docs/PLAYBACK_MATRIX.md).
//
// Scope is deliberately narrow: enough to stream-copy the elementary streams
// into fMP4. It indexes via SeekHead + Cues rather than scanning, so a 65 GB
// source costs a few MB of ranged reads to index (measured in the #176 spike).

/// Abstract random-access byte source the demuxer reads through.
public protocol MatroskaByteSource: Sendable {
    /// Total size of the underlying file in bytes.
    var length: UInt64 { get }
    /// Read `count` bytes at `offset`. May return fewer only at end of file.
    func read(at offset: UInt64, count: Int) async throws -> Data
}

/// An in-memory source, for tests and small files.
public struct DataByteSource: MatroskaByteSource {
    private let data: Data
    public init(_ data: Data) {
        self.data = data
    }

    public var length: UInt64 {
        UInt64(data.count)
    }

    public func read(at offset: UInt64, count: Int) async throws -> Data {
        guard offset < UInt64(data.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + count, data.count)
        return data.subdata(in: (data.startIndex + start) ..< (data.startIndex + end))
    }
}

public enum MatroskaError: Error, Equatable {
    /// Not an EBML/Matroska file at all.
    case notMatroska
    /// Structurally broken in a way the demuxer cannot recover from.
    case malformed(String)
    /// No Cues index — the file cannot be seeked without a full scan, so the
    /// caller must refuse it back to the server path rather than ship a
    /// broken scrubber (#176 requirement).
    case unseekable
}

// MARK: - Index model

public struct MatroskaTrack: Sendable, Equatable {
    public enum TrackType: Int, Sendable {
        case video = 1, audio = 2, complex = 3, logo = 16, subtitle = 17, buttons = 18, control = 32, metadata = 33
        case unknown = 0
    }

    public var number: Int = 0
    public var type: TrackType = .unknown
    public var codecID: String = ""
    public var codecPrivate: Data?
    public var isDefault: Bool = true
    /// Nominal frame/sample duration in nanoseconds, when declared.
    public var defaultDurationNs: UInt64?
    public var language: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var channels: Int?
    public var samplingFrequency: Double?
    /// Track-level BlockAdditionMapping entries. For Dolby Vision sources the
    /// `dvcC`/`dvvC` configuration record arrives here (type 'dvcC'/'dvvC',
    /// extra data = the box payload) — the box ffmpeg refuses to write is
    /// handed to us by the source (#176 spike finding 3).
    public var blockAdditionMappings: [BlockAdditionMapping] = []

    public struct BlockAdditionMapping: Sendable, Equatable {
        public var type: UInt32 = 0
        public var value: UInt64 = 0
        public var extraData: Data?
    }
}

public struct MatroskaCuePoint: Sendable, Equatable {
    /// Cue time in timestamp ticks (see `MatroskaIndex.timestampScaleNs`).
    public var timeTicks: UInt64
    /// Absolute file offset of the Cluster this cue lands on.
    public var clusterOffset: UInt64
}

public struct MatroskaIndex: Sendable {
    /// Nanoseconds per timestamp tick (Matroska default: 1_000_000 = 1ms).
    public let timestampScaleNs: UInt64
    /// Total duration in ticks, when the file declares one.
    public let durationTicks: Double?
    public let tracks: [MatroskaTrack]
    /// Cue points deduplicated to one per cluster, ascending by offset.
    public let cues: [MatroskaCuePoint]
    /// Absolute file offset where the Segment's content starts; Matroska
    /// seek/cue positions are relative to this.
    public let segmentDataStart: UInt64
    /// Absolute end of the Segment's content (start + declared size, clamped
    /// to file length), used to bound the final cluster.
    public let segmentDataEnd: UInt64

    public var durationSeconds: Double? {
        durationTicks.map { $0 * Double(timestampScaleNs) / 1e9 }
    }
}

// MARK: - Cluster model

/// One frame after lacing is unrolled: the payload is exactly one video
/// access unit / audio frame.
public struct MatroskaFrame: Sendable {
    public let trackNumber: Int
    /// Presentation time in ticks (cluster timestamp + block offset). Laced
    /// frames all carry the block's time; spreading them is the caller's job.
    public let timeTicks: Int64
    public let isKeyframe: Bool
    public let data: Data
    /// Position within the block's lace (0-based) and the lace's frame count.
    /// Callers spreading timestamps over an undated lace need both.
    public let laceIndex: Int
    public let laceCount: Int
}

public struct MatroskaCluster: Sendable {
    public let timestampTicks: UInt64
    /// Frames in storage (decode) order across all tracks.
    public let frames: [MatroskaFrame]
}

// MARK: - Demuxer

public struct MatroskaDemuxer: Sendable {
    private let source: MatroskaByteSource

    /// How much of the head to fetch when looking for SeekHead/Info/Tracks.
    /// The spike measured real 25–65 GB sources needing well under this.
    private static let headFetchSize = 256 * 1024
    /// Upper bound on a single element fetch (Cues on a 65 GB source measured
    /// 3.7 MB; anything past this is treated as malformed).
    private static let maxElementSize = 64 * 1024 * 1024

    public init(source: MatroskaByteSource) {
        self.source = source
    }

    // MARK: Index

    /// Parse EBML header, SeekHead, Info, Tracks, and Cues — everything
    /// needed to plan a remux — without touching cluster data.
    public func loadIndex() async throws -> MatroskaIndex {
        let head = try await source.read(at: 0, count: Self.headFetchSize)
        var cursor = EBMLCursor(data: head, base: 0)

        guard let ebmlID = cursor.readID(), ebmlID == MatroskaID.ebmlHeader,
              let ebmlSizeOpt = cursor.readSize(), let ebmlSize = ebmlSizeOpt
        else { throw MatroskaError.notMatroska }
        cursor.skip(ebmlSize)

        guard let segmentID = cursor.readID(), segmentID == MatroskaID.segment,
              let segmentSizeOpt = cursor.readSize()
        else { throw MatroskaError.notMatroska }
        let segmentDataStart = cursor.absolute
        let segmentDataEnd = segmentSizeOpt.map { min(segmentDataStart + UInt64($0), source.length) } ?? source.length

        // Walk the Segment's level-1 elements present in the head window,
        // collecting SeekHead pointers as we go.
        var seekEntries: [(id: UInt32, position: UInt64)] = []
        var info: InfoElement?
        var tracks: [MatroskaTrack]?
        var cuesData: (data: Data, base: UInt64)?

        var walker = cursor
        while walker.remaining > 0 {
            guard let id = walker.readID(), let sizeOpt = walker.readSize(), let size = sizeOpt else { break }
            let contentStart = walker.pos
            // Stop at the first cluster — everything else is behind SeekHead.
            if id == MatroskaID.cluster {
                break
            }
            if contentStart + size > walker.data.count, id != MatroskaID.seekHead {
                // Element extends past the head window; fetch it individually
                // below if SeekHead points at it.
                break
            }
            switch id {
            case MatroskaID.seekHead:
                let end = min(contentStart + size, walker.data.count)
                seekEntries.append(contentsOf: Self.parseSeekHead(walker.data, contentStart, end, base: walker.base))
            case MatroskaID.info:
                info = Self.parseInfo(walker.data, contentStart, contentStart + size)
            case MatroskaID.tracks:
                tracks = Self.parseTracks(walker.data, contentStart, contentStart + size, base: walker.base)
            case MatroskaID.cues:
                cuesData = (walker.data.subdata(in: (walker.data.startIndex + contentStart) ..< (walker.data.startIndex + contentStart + size)), walker.base + UInt64(contentStart))
            default:
                break
            }
            walker.pos = contentStart + size
        }

        // Anything the head window didn't cover, fetch via its SeekHead
        // pointer. Cues in particular usually live at the end of the file.
        for entry in seekEntries {
            let offset = segmentDataStart + entry.position
            switch entry.id {
            case MatroskaID.info where info == nil:
                let element = try await fetchElement(at: offset, expecting: MatroskaID.info)
                info = Self.parseInfo(element.data, 0, element.data.count)
            case MatroskaID.tracks where tracks == nil:
                let element = try await fetchElement(at: offset, expecting: MatroskaID.tracks)
                tracks = Self.parseTracks(element.data, 0, element.data.count, base: element.base)
            case MatroskaID.cues where cuesData == nil:
                let element = try await fetchElement(at: offset, expecting: MatroskaID.cues)
                cuesData = (element.data, element.base)
            default:
                break
            }
        }

        guard let info else { throw MatroskaError.malformed("no Info element") }
        guard let tracks, !tracks.isEmpty else { throw MatroskaError.malformed("no Tracks element") }
        guard let cuesData else { throw MatroskaError.unseekable }

        let cues = Self.parseCues(cuesData.data, segmentDataStart: segmentDataStart)
        guard !cues.isEmpty else { throw MatroskaError.unseekable }

        return MatroskaIndex(
            timestampScaleNs: info.timestampScale,
            durationTicks: info.durationTicks,
            tracks: tracks,
            cues: cues,
            segmentDataStart: segmentDataStart,
            segmentDataEnd: segmentDataEnd,
        )
    }

    // MARK: Clusters

    /// Read and unroll every cluster in `[offset, endBound)` — one cue-to-cue
    /// span. Spans, not single clusters, because Cues follow video keyframes:
    /// a long-GOP source has clusters no cue references, and reading only the
    /// cued one would silently drop their content. `offset` must come from a
    /// cue point; `endBound` is the next cue's cluster offset or the segment
    /// end.
    public func readClusters(from offset: UInt64, to endBound: UInt64) async throws -> MatroskaCluster {
        var timestampTicks: UInt64?
        var frames: [MatroskaFrame] = []
        var cursor = offset
        while cursor < endBound {
            let header = try await elementHeader(at: cursor)
            guard header.id == MatroskaID.cluster else {
                if timestampTicks == nil {
                    throw MatroskaError.malformed("cue offset did not land on a Cluster")
                }
                // Non-cluster element after the first cluster (Void, or the
                // start of the trailing Cues/Tags region): the span is done.
                break
            }
            // Unknown-size clusters (streamed muxes) are bounded by the span.
            let contentEnd = header.size.map { header.contentStart + UInt64($0) } ?? endBound
            let byteCount = Int(min(contentEnd, endBound) - header.contentStart)
            guard byteCount >= 0, byteCount <= Self.maxElementSize else {
                throw MatroskaError.malformed("cluster size \(byteCount) out of range")
            }
            let data = try await source.read(at: header.contentStart, count: byteCount)
            let cluster = try Self.parseCluster(data)
            if timestampTicks == nil {
                timestampTicks = cluster.timestampTicks
            }
            frames.append(contentsOf: cluster.frames)
            cursor = header.contentStart + UInt64(byteCount)
        }
        guard let timestampTicks else {
            throw MatroskaError.malformed("empty cluster span at \(offset)")
        }
        return MatroskaCluster(timestampTicks: timestampTicks, frames: frames)
    }

    // MARK: - Element fetching

    private func elementHeader(at offset: UInt64) async throws -> (id: UInt32, contentStart: UInt64, size: Int?) {
        let probe = try await source.read(at: offset, count: 16)
        var c = EBMLCursor(data: probe, base: offset)
        guard let id = c.readID(), let sizeOpt = c.readSize() else {
            throw MatroskaError.malformed("unreadable element header at \(offset)")
        }
        return (id, offset + UInt64(c.pos), sizeOpt)
    }

    private func fetchElement(at offset: UInt64, expecting id: UInt32) async throws -> (data: Data, base: UInt64) {
        let header = try await elementHeader(at: offset)
        guard header.id == id else {
            throw MatroskaError.malformed("SeekHead offset did not land on expected element")
        }
        guard let size = header.size, size <= Self.maxElementSize else {
            throw MatroskaError.malformed("element at \(offset) has no usable size")
        }
        let data = try await source.read(at: header.contentStart, count: size)
        guard data.count == size else {
            throw MatroskaError.malformed("truncated element at \(offset)")
        }
        return (data, header.contentStart)
    }

    // MARK: - Head parsers (pure, synchronous)

    private static func parseSeekHead(_ data: Data, _ start: Int, _ end: Int, base: UInt64) -> [(id: UInt32, position: UInt64)] {
        var entries: [(UInt32, UInt64)] = []
        var c = EBMLCursor(data: data, base: base, pos: start)
        while c.pos < end {
            guard let id = c.readID(), let sizeOpt = c.readSize(), let size = sizeOpt else { break }
            let contentStart = c.pos
            if id == MatroskaID.seek {
                var target: UInt32 = 0
                var position: UInt64 = 0
                var sub = EBMLCursor(data: data, base: base, pos: contentStart)
                let subEnd = contentStart + size
                while sub.pos < subEnd {
                    guard let sid = sub.readID(), let ssOpt = sub.readSize(), let ss = ssOpt else { break }
                    if sid == MatroskaID.seekID, let d = sub.peek(ss) {
                        target = UInt32(EBMLCursor.uint(d))
                    }
                    if sid == MatroskaID.seekPosition, let d = sub.peek(ss) {
                        position = EBMLCursor.uint(d)
                    }
                    sub.skip(ss)
                }
                if target != 0 {
                    entries.append((target, position))
                }
            }
            c.pos = contentStart + size
        }
        return entries
    }

    private struct InfoElement {
        var timestampScale: UInt64 = 1_000_000
        var durationTicks: Double?
    }

    private static func parseInfo(_ data: Data, _ start: Int, _ end: Int) -> InfoElement {
        var info = InfoElement()
        var c = EBMLCursor(data: data, base: 0, pos: start)
        let bounded = min(end, data.count)
        while c.pos < bounded {
            guard let id = c.readID(), let sizeOpt = c.readSize(), let size = sizeOpt else { break }
            if id == MatroskaID.timestampScale, let d = c.peek(size) {
                info.timestampScale = EBMLCursor.uint(d)
            }
            if id == MatroskaID.duration, let d = c.peek(size) {
                info.durationTicks = EBMLCursor.float(d)
            }
            c.skip(size)
        }
        return info
    }

    private static func parseTracks(_ data: Data, _ start: Int, _ end: Int, base: UInt64) -> [MatroskaTrack] {
        var tracks: [MatroskaTrack] = []
        var c = EBMLCursor(data: data, base: base, pos: start)
        let bounded = min(end, data.count)
        while c.pos < bounded {
            guard let id = c.readID(), let sizeOpt = c.readSize(), let size = sizeOpt else { break }
            let contentStart = c.pos
            if id == MatroskaID.trackEntry {
                tracks.append(parseTrackEntry(data, contentStart, size, base: base))
            }
            c.pos = contentStart + size
        }
        return tracks
    }

    private static func parseTrackEntry(_ data: Data, _ start: Int, _ size: Int, base: UInt64) -> MatroskaTrack {
        var t = MatroskaTrack()
        var c = EBMLCursor(data: data, base: base, pos: start)
        let end = start + size
        while c.pos < end {
            guard let id = c.readID(), let sizeOpt = c.readSize(), let ss = sizeOpt else { break }
            switch id {
            case MatroskaID.trackNumber: if let d = c.peek(ss) {
                    t.number = Int(EBMLCursor.uint(d))
                }
            case MatroskaID.trackType: if let d = c.peek(ss) {
                    t.type = MatroskaTrack.TrackType(rawValue: Int(EBMLCursor.uint(d))) ?? .unknown
                }
            case MatroskaID.flagDefault: if let d = c.peek(ss) {
                    t.isDefault = EBMLCursor.uint(d) != 0
                }
            case MatroskaID.defaultDuration: if let d = c.peek(ss) {
                    t.defaultDurationNs = EBMLCursor.uint(d)
                }
            case MatroskaID.language: if let d = c.peek(ss) {
                    t.language = String(decoding: d, as: UTF8.self)
                }
            case MatroskaID.codecID: if let d = c.peek(ss) {
                    t.codecID = String(decoding: d, as: UTF8.self)
                }
            case MatroskaID.codecPrivate: t.codecPrivate = c.peek(ss)
            case MatroskaID.blockAdditionMapping:
                var mapping = MatroskaTrack.BlockAdditionMapping()
                var sub = EBMLCursor(data: data, base: base, pos: c.pos)
                let subEnd = c.pos + ss
                while sub.pos < subEnd {
                    guard let mid = sub.readID(), let msOpt = sub.readSize(), let ms = msOpt else { break }
                    if mid == MatroskaID.blockAddIDType, let d = sub.peek(ms) {
                        mapping.type = UInt32(EBMLCursor.uint(d))
                    }
                    if mid == MatroskaID.blockAddIDValue, let d = sub.peek(ms) {
                        mapping.value = EBMLCursor.uint(d)
                    }
                    if mid == MatroskaID.blockAddIDExtraData {
                        mapping.extraData = sub.peek(ms)
                    }
                    sub.skip(ms)
                }
                t.blockAdditionMappings.append(mapping)
            case MatroskaID.video, MatroskaID.audio:
                var sub = EBMLCursor(data: data, base: base, pos: c.pos)
                let subEnd = c.pos + ss
                while sub.pos < subEnd {
                    guard let iid = sub.readID(), let isOpt = sub.readSize(), let isz = isOpt else { break }
                    switch iid {
                    case MatroskaID.pixelWidth: if let d = sub.peek(isz) {
                            t.pixelWidth = Int(EBMLCursor.uint(d))
                        }
                    case MatroskaID.pixelHeight: if let d = sub.peek(isz) {
                            t.pixelHeight = Int(EBMLCursor.uint(d))
                        }
                    case MatroskaID.channels: if let d = sub.peek(isz) {
                            t.channels = Int(EBMLCursor.uint(d))
                        }
                    case MatroskaID.samplingFrequency: if let d = sub.peek(isz) {
                            t.samplingFrequency = EBMLCursor.float(d)
                        }
                    default: break
                    }
                    sub.skip(isz)
                }
            default: break
            }
            c.skip(ss)
        }
        return t
    }

    private static func parseCues(_ data: Data, segmentDataStart: UInt64) -> [MatroskaCuePoint] {
        // One cue per cluster: sources index many tracks against the same
        // cluster (the spike's 37-track file carried 78k cue points), and the
        // remux plans fragments per cluster, not per track.
        var byOffset: [UInt64: UInt64] = [:] // clusterOffset -> earliest time
        var c = EBMLCursor(data: data, base: 0)
        while c.remaining > 0 {
            guard let id = c.readID(), let sizeOpt = c.readSize(), let size = sizeOpt else { break }
            let start = c.pos
            if id == MatroskaID.cuePoint {
                var time: UInt64 = 0
                var clusterPosition: UInt64?
                var sub = EBMLCursor(data: data, base: 0, pos: start)
                let end = start + size
                while sub.pos < end {
                    guard let sid = sub.readID(), let ssOpt = sub.readSize(), let ss = ssOpt else { break }
                    if sid == MatroskaID.cueTime, let d = sub.peek(ss) {
                        time = EBMLCursor.uint(d)
                    }
                    if sid == MatroskaID.cueTrackPositions {
                        var inner = EBMLCursor(data: data, base: 0, pos: sub.pos)
                        let innerEnd = sub.pos + ss
                        while inner.pos < innerEnd {
                            guard let iid = inner.readID(), let isOpt = inner.readSize(), let isz = isOpt else { break }
                            if iid == MatroskaID.cueClusterPosition, let d = inner.peek(isz) {
                                clusterPosition = EBMLCursor.uint(d)
                            }
                            inner.skip(isz)
                        }
                    }
                    sub.skip(ss)
                }
                if let clusterPosition {
                    let absolute = segmentDataStart + clusterPosition
                    byOffset[absolute] = min(byOffset[absolute] ?? .max, time)
                }
            }
            c.pos = start + size
        }
        return byOffset
            .map { MatroskaCuePoint(timeTicks: $0.value, clusterOffset: $0.key) }
            .sorted { $0.clusterOffset < $1.clusterOffset }
    }

    // MARK: - Cluster parser (pure, synchronous)

    static func parseCluster(_ data: Data) throws -> MatroskaCluster {
        var timestamp: UInt64 = 0
        var frames: [MatroskaFrame] = []
        var c = EBMLCursor(data: data, base: 0)
        while c.remaining > 0 {
            guard let id = c.readID(), let sizeOpt = c.readSize(), let size = sizeOpt else { break }
            let start = c.pos
            switch id {
            case MatroskaID.clusterTimestamp:
                if let d = c.peek(size) {
                    timestamp = EBMLCursor.uint(d)
                }
            case MatroskaID.simpleBlock:
                var sub = EBMLCursor(data: data, base: 0, pos: start)
                try appendBlockFrames(&sub, blockEnd: start + size, clusterTimestamp: timestamp, keyframe: nil, into: &frames)
            case MatroskaID.blockGroup:
                // Keyframe determination is per-track: a BlockGroup with no
                // ReferenceBlock is a keyframe for video, but subtitles also
                // arrive as BlockGroups and must not be miscounted (#176
                // spike finding — remaining-work list).
                var blockStart: Int?
                var blockSize = 0
                var hasReference = false
                var sub = EBMLCursor(data: data, base: 0, pos: start)
                let end = start + size
                while sub.pos < end {
                    guard let gid = sub.readID(), let gsOpt = sub.readSize(), let gs = gsOpt else { break }
                    if gid == MatroskaID.block {
                        blockStart = sub.pos
                        blockSize = gs
                    }
                    if gid == MatroskaID.referenceBlock {
                        hasReference = true
                    }
                    sub.skip(gs)
                }
                if let blockStart {
                    var inner = EBMLCursor(data: data, base: 0, pos: blockStart)
                    try appendBlockFrames(&inner, blockEnd: blockStart + blockSize, clusterTimestamp: timestamp, keyframe: !hasReference, into: &frames)
                }
            default:
                break
            }
            c.pos = start + size
        }
        return MatroskaCluster(timestampTicks: timestamp, frames: frames)
    }

    /// Parse one (Simple)Block: header, lacing, then append one frame per
    /// lace entry. `keyframe` is `nil` for SimpleBlocks (flag bit carries it)
    /// and the BlockGroup's ReferenceBlock-derived value otherwise.
    private static func appendBlockFrames(
        _ c: inout EBMLCursor,
        blockEnd: Int,
        clusterTimestamp: UInt64,
        keyframe: Bool?,
        into frames: inout [MatroskaFrame],
    ) throws {
        guard let trackOpt = c.readSize(), let track = trackOpt,
              let hi = c.byte(), let lo = c.byte(), let flags = c.byte()
        else { throw MatroskaError.malformed("unreadable block header") }
        let relative = Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo))
        let blockTime = Int64(clusterTimestamp) + Int64(relative)
        let isKeyframe = keyframe ?? (flags & 0x80 != 0)

        let sizes = try laceSizes(&c, flags: flags, blockEnd: blockEnd)
        for (index, size) in sizes.enumerated() {
            guard let payload = c.take(size) else {
                throw MatroskaError.malformed("laced frame overruns block")
            }
            frames.append(MatroskaFrame(
                trackNumber: track,
                timeTicks: blockTime,
                isKeyframe: isKeyframe && index == 0,
                data: Data(payload),
                laceIndex: index,
                laceCount: sizes.count,
            ))
        }
    }

    /// Frame sizes for the block's lacing mode. All three modes occur in the
    /// wild (#176 spike): 0b00 none, 0b01 Xiph, 0b10 fixed, 0b11 EBML.
    private static func laceSizes(_ c: inout EBMLCursor, flags: UInt8, blockEnd: Int) throws -> [Int] {
        let lacing = (flags & 0x06) >> 1
        if lacing == 0 {
            return [blockEnd - c.pos]
        }

        guard let countMinusOne = c.byte() else { throw MatroskaError.malformed("missing lace count") }
        let frameCount = Int(countMinusOne) + 1
        if frameCount == 1 {
            return [blockEnd - c.pos]
        }

        switch lacing {
        case 1: // Xiph: sizes as 255-run sums for all but the last frame
            var sizes: [Int] = []
            for _ in 0 ..< frameCount - 1 {
                var size = 0
                while true {
                    guard let b = c.byte() else { throw MatroskaError.malformed("truncated Xiph lace") }
                    size += Int(b)
                    if b != 255 {
                        break
                    }
                }
                sizes.append(size)
            }
            let consumed = sizes.reduce(0, +)
            let last = blockEnd - c.pos - consumed
            guard last >= 0 else { throw MatroskaError.malformed("Xiph lace overruns block") }
            sizes.append(last)
            return sizes
        case 2: // fixed: equal split of the remaining payload
            let payload = blockEnd - c.pos
            guard payload % frameCount == 0 else { throw MatroskaError.malformed("fixed lace not divisible") }
            return Array(repeating: payload / frameCount, count: frameCount)
        default: // 3, EBML: first size as VINT, then signed deltas
            guard let firstOpt = c.readSize(), let first = firstOpt else {
                throw MatroskaError.malformed("truncated EBML lace")
            }
            var sizes = [first]
            for _ in 1 ..< frameCount - 1 {
                guard let delta = c.readSignedVINT(), let previous = sizes.last else {
                    throw MatroskaError.malformed("truncated EBML lace delta")
                }
                let size = previous + delta
                guard size >= 0 else { throw MatroskaError.malformed("negative EBML lace size") }
                sizes.append(size)
            }
            let consumed = sizes.reduce(0, +)
            let last = blockEnd - c.pos - consumed
            guard last >= 0 else { throw MatroskaError.malformed("EBML lace overruns block") }
            if frameCount > 1 {
                sizes.append(last)
            }
            return sizes
        }
    }
}

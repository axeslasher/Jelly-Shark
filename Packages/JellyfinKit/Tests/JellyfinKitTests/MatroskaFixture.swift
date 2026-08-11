import Foundation
@testable import JellyfinKit

// Hand-built EBML/Matroska fixtures for the remux tests (#176). The real
// ffmpeg-muxed file in Fixtures/ covers the common shape; these cover the
// shapes ffmpeg never writes — all three lacing modes, BlockGroups with and
// without ReferenceBlock, SeekHead-at-head with Cues-at-end, missing Cues.

enum EBMLWriter {
    /// Encode a value as an EBML VINT (size encoding, marker bit included).
    static func vint(_ value: Int) -> Data {
        var width = 1
        while value >= (1 << (7 * width)) - 1, width < 8 {
            width += 1
        }
        var bytes = [UInt8](repeating: 0, count: width)
        var v = UInt64(value)
        for i in stride(from: width - 1, through: 0, by: -1) {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (width - 1))
        return Data(bytes)
    }

    /// A signed VINT for EBML lace deltas.
    static func signedVint(_ value: Int) -> Data {
        var width = 1
        while abs(value) >= (1 << (7 * width - 1)) - 1, width < 8 {
            width += 1
        }
        let bias = (1 << (7 * width - 1)) - 1
        var bytes = [UInt8](repeating: 0, count: width)
        var v = UInt64(value + bias)
        for i in stride(from: width - 1, through: 0, by: -1) {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        bytes[0] |= UInt8(0x80 >> (width - 1))
        return Data(bytes)
    }

    /// Raw element ID bytes (IDs carry their own marker bit already).
    static func id(_ value: UInt32) -> Data {
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return Data(bytes)
    }

    static func element(_ elementID: UInt32, _ payload: Data) -> Data {
        id(elementID) + vint(payload.count) + payload
    }

    static func uintElement(_ elementID: UInt32, _ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return element(elementID, Data(bytes))
    }

    static func floatElement(_ elementID: UInt32, _ value: Double) -> Data {
        var bits = value.bitPattern.bigEndian
        return element(elementID, withUnsafeBytes(of: &bits) { Data($0) })
    }

    static func stringElement(_ elementID: UInt32, _ value: String) -> Data {
        element(elementID, Data(value.utf8))
    }
}

/// Assembles a minimal but structurally honest MKV.
struct MatroskaFixtureBuilder {
    struct Track {
        var number: Int
        var type: Int // 1 video, 2 audio, 17 subtitle
        var codecID: String
        var codecPrivate: Data?
        var defaultDurationNs: UInt64?
        var isDefault = true
        var width: Int?
        var height: Int?
        var channels: Int?
        var samplingFrequency: Double?
        /// (fourcc, extra data) pairs emitted as BlockAdditionMapping.
        var additionMappings: [(String, Data)] = []
    }

    enum Lacing {
        case none
        case xiph
        case fixed
        case ebml
    }

    struct Block {
        var track: Int
        var relativeTime: Int16
        var keyframe: Bool
        /// One payload per laced frame (single element for no lacing).
        var framePayloads: [Data]
        var lacing: Lacing = .none
        /// Emit as BlockGroup rather than SimpleBlock; `referenceBlock`
        /// controls whether a ReferenceBlock child marks it non-key.
        var asBlockGroup = false
        var referenceBlock: Int?
    }

    struct Cluster {
        var timestamp: UInt64
        var blocks: [Block]
    }

    var timestampScale: UInt64 = 1_000_000
    var durationTicks: Double? = 8000
    var tracks: [Track] = []
    var clusters: [Cluster] = []
    var includeCues = true
    /// Put Cues behind a SeekHead at the end of the segment (the real-world
    /// shape) instead of before the clusters.
    var cuesAtEnd = false

    func build() -> Data {
        let ebmlHeader = EBMLWriter.element(0x1A45_DFA3, EBMLWriter.uintElement(0x4286, 1) // EBMLVersion
            + EBMLWriter.uintElement(0x42F7, 1) // EBMLReadVersion
            + EBMLWriter.stringElement(0x4282, "matroska")
            + EBMLWriter.uintElement(0x4287, 4) // DocTypeVersion
            + EBMLWriter.uintElement(0x4285, 2)) // DocTypeReadVersion

        var infoPayload = EBMLWriter.uintElement(MatroskaID.timestampScale, timestampScale)
        if let durationTicks {
            infoPayload += EBMLWriter.floatElement(MatroskaID.duration, durationTicks)
        }
        let info = EBMLWriter.element(MatroskaID.info, infoPayload)

        let tracksElement = EBMLWriter.element(
            MatroskaID.tracks,
            tracks.reduce(Data()) { $0 + trackEntry($1) },
        )

        let clusterElements = clusters.map { clusterElement($0) }

        // Assemble the segment payload, then compute cue offsets (relative to
        // the segment data start) from the running position.
        var segmentPayload = Data()
        var clusterOffsets: [UInt64] = []

        func appendClusters() {
            for element in clusterElements {
                clusterOffsets.append(UInt64(segmentPayload.count))
                segmentPayload += element
            }
        }

        if cuesAtEnd {
            // SeekHead with an 8-byte padded position so its size is stable.
            let seekHeadSize = seekHead(cuesPosition: 0).count
            var body = Data()
            var position = UInt64(seekHeadSize + info.count + tracksElement.count)
            for element in clusterElements {
                clusterOffsets.append(position)
                body += element
                position += UInt64(element.count)
            }
            let head = seekHead(cuesPosition: position)
            segmentPayload = head + info + tracksElement + body
            if includeCues {
                segmentPayload += cuesElement(clusterOffsets: clusterOffsets)
            }
        } else {
            segmentPayload = info + tracksElement
            if includeCues {
                // Cues before clusters: offsets depend on the cues element's
                // own size (and offsets crossing a VINT width boundary grow
                // it), so iterate to a fixed point.
                var cues = Data()
                var previousSize = -1
                while cues.count != previousSize {
                    previousSize = cues.count
                    var offsets: [UInt64] = []
                    var position = UInt64((info + tracksElement + cues).count)
                    for element in clusterElements {
                        offsets.append(position)
                        position += UInt64(element.count)
                    }
                    cues = cuesElement(clusterOffsets: offsets)
                    clusterOffsets = offsets
                }
                segmentPayload += cues
            }
            appendClusters()
        }

        return ebmlHeader + EBMLWriter.element(MatroskaID.segment, segmentPayload)
    }

    private func seekHead(cuesPosition: UInt64) -> Data {
        var positionBytes = Data(count: 8)
        var v = cuesPosition
        for i in stride(from: 7, through: 0, by: -1) {
            positionBytes[positionBytes.startIndex + i] = UInt8(v & 0xFF)
            v >>= 8
        }
        let seek = EBMLWriter.element(
            MatroskaID.seek,
            EBMLWriter.element(MatroskaID.seekID, EBMLWriter.id(MatroskaID.cues))
                + EBMLWriter.element(MatroskaID.seekPosition, positionBytes),
        )
        return EBMLWriter.element(MatroskaID.seekHead, seek)
    }

    private func trackEntry(_ track: Track) -> Data {
        var payload = EBMLWriter.uintElement(MatroskaID.trackNumber, UInt64(track.number))
        payload += EBMLWriter.uintElement(MatroskaID.trackType, UInt64(track.type))
        payload += EBMLWriter.uintElement(MatroskaID.flagDefault, track.isDefault ? 1 : 0)
        payload += EBMLWriter.stringElement(MatroskaID.codecID, track.codecID)
        if let defaultDurationNs = track.defaultDurationNs {
            payload += EBMLWriter.uintElement(MatroskaID.defaultDuration, defaultDurationNs)
        }
        if let codecPrivate = track.codecPrivate {
            payload += EBMLWriter.element(MatroskaID.codecPrivate, codecPrivate)
        }
        for (fourcc, extra) in track.additionMappings {
            let fourccValue = Data(fourcc.utf8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            payload += EBMLWriter.element(
                MatroskaID.blockAdditionMapping,
                EBMLWriter.uintElement(MatroskaID.blockAddIDValue, 1)
                    + EBMLWriter.uintElement(MatroskaID.blockAddIDType, fourccValue)
                    + EBMLWriter.element(MatroskaID.blockAddIDExtraData, extra),
            )
        }
        if track.type == 1 {
            var video = Data()
            if let width = track.width {
                video += EBMLWriter.uintElement(MatroskaID.pixelWidth, UInt64(width))
            }
            if let height = track.height {
                video += EBMLWriter.uintElement(MatroskaID.pixelHeight, UInt64(height))
            }
            payload += EBMLWriter.element(MatroskaID.video, video)
        }
        if track.type == 2 {
            var audio = Data()
            if let channels = track.channels {
                audio += EBMLWriter.uintElement(MatroskaID.channels, UInt64(channels))
            }
            if let rate = track.samplingFrequency {
                audio += EBMLWriter.floatElement(MatroskaID.samplingFrequency, rate)
            }
            payload += EBMLWriter.element(MatroskaID.audio, audio)
        }
        return EBMLWriter.element(MatroskaID.trackEntry, payload)
    }

    private func cuesElement(clusterOffsets: [UInt64]) -> Data {
        var cuePoints = Data()
        for (index, offset) in clusterOffsets.enumerated() {
            let cluster = clusters[index]
            cuePoints += EBMLWriter.element(
                MatroskaID.cuePoint,
                EBMLWriter.uintElement(MatroskaID.cueTime, cluster.timestamp)
                    + EBMLWriter.element(
                        MatroskaID.cueTrackPositions,
                        EBMLWriter.uintElement(MatroskaID.cueTrack, UInt64(tracks.first?.number ?? 1))
                            + EBMLWriter.uintElement(MatroskaID.cueClusterPosition, offset),
                    ),
            )
        }
        return EBMLWriter.element(MatroskaID.cues, cuePoints)
    }

    private func clusterElement(_ cluster: Cluster) -> Data {
        var payload = EBMLWriter.uintElement(MatroskaID.clusterTimestamp, cluster.timestamp)
        for block in cluster.blocks {
            payload += blockElement(block)
        }
        return EBMLWriter.element(MatroskaID.cluster, payload)
    }

    private func blockElement(_ block: Block) -> Data {
        var body = EBMLWriter.vint(block.track)
        body += Data([UInt8(bitPattern: Int8(block.relativeTime >> 8)), UInt8(truncatingIfNeeded: block.relativeTime)])

        var flags: UInt8 = 0
        if !block.asBlockGroup, block.keyframe {
            flags |= 0x80
        }

        switch block.lacing {
        case .none:
            body += Data([flags])
            body += block.framePayloads[0]
        case .xiph:
            body += Data([flags | 0x02, UInt8(block.framePayloads.count - 1)])
            for payload in block.framePayloads.dropLast() {
                var size = payload.count
                while size >= 255 {
                    body += Data([255])
                    size -= 255
                }
                body += Data([UInt8(size)])
            }
            block.framePayloads.forEach { body += $0 }
        case .fixed:
            body += Data([flags | 0x04, UInt8(block.framePayloads.count - 1)])
            block.framePayloads.forEach { body += $0 }
        case .ebml:
            body += Data([flags | 0x06, UInt8(block.framePayloads.count - 1)])
            body += EBMLWriter.vint(block.framePayloads[0].count)
            var previous = block.framePayloads[0].count
            for payload in block.framePayloads.dropFirst().dropLast() {
                body += EBMLWriter.signedVint(payload.count - previous)
                previous = payload.count
            }
            block.framePayloads.forEach { body += $0 }
        }

        if block.asBlockGroup {
            var group = EBMLWriter.element(MatroskaID.block, body)
            if let reference = block.referenceBlock {
                group += EBMLWriter.element(MatroskaID.referenceBlock, Data([UInt8(bitPattern: Int8(truncatingIfNeeded: reference))]))
            }
            return EBMLWriter.element(MatroskaID.blockGroup, group)
        }
        return EBMLWriter.element(MatroskaID.simpleBlock, body)
    }
}

// MARK: - MP4 box reader

/// Minimal ISO-BMFF box walker for asserting on muxer output.
struct MP4Box {
    let type: String
    let payload: Data

    static func parse(_ data: Data) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            let size = data[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let type = String(decoding: data[offset + 4 ..< offset + 8], as: UTF8.self)
            guard size >= 8, offset + size <= data.endIndex else { break }
            boxes.append(MP4Box(type: type, payload: Data(data[offset + 8 ..< offset + size])))
            offset += size
        }
        return boxes
    }

    var children: [MP4Box] {
        Self.parse(payload)
    }

    /// First box at a slash-separated path, e.g. "moov/trak/mdia".
    static func find(_ path: String, in data: Data) -> MP4Box? {
        var boxes = parse(data)
        var result: MP4Box?
        for component in path.split(separator: "/") {
            guard let match = boxes.first(where: { $0.type == component }) else { return nil }
            result = match
            boxes = match.children
        }
        return result
    }

    /// All boxes matching the final path component under the given path.
    static func findAll(_ path: String, in data: Data) -> [MP4Box] {
        let components = path.split(separator: "/")
        guard let last = components.last else { return [] }
        var boxes = parse(data)
        for component in components.dropLast() {
            guard let match = boxes.first(where: { $0.type == component }) else { return [] }
            boxes = match.children
        }
        return boxes.filter { $0.type == last }
    }
}

// MARK: - Shared codec fixtures

enum CodecFixtures {
    /// A minimal but well-formed hvcC record: version 1, Main 10, NAL length
    /// prefix width 4, no parameter-set arrays.
    static var hvcC: Data {
        var record = Data([1]) // configurationVersion
        record += Data([0x02]) // profile_space 0, tier 0, profile_idc 2 (Main 10)
        record += Data([0x20, 0x00, 0x00, 0x00]) // profile_compatibility
        record += Data([0x90, 0x00, 0x00, 0x00, 0x00, 0x00]) // constraints
        record += Data([123]) // level_idc
        record += Data([0xF0, 0x00]) // spatial segmentation
        record += Data([0xFC]) // parallelism
        record += Data([0xFD]) // chroma_format 4:2:0
        record += Data([0xFA]) // bit_depth_luma - 8 = 2
        record += Data([0xFA]) // bit_depth_chroma - 8 = 2
        record += Data([0x00, 0x00]) // avg frame rate
        record += Data([0x0F]) // constantFrameRate 0, numTemporalLayers 1, temporalIdNested 1, lengthSizeMinusOne 3
        record += Data([0x00]) // numOfArrays
        return record
    }

    /// A length-prefixed HEVC access unit assembled from (nalType, bodySize)
    /// pairs, 4-byte prefixes.
    static func hevcAccessUnit(_ nals: [(type: UInt8, size: Int)]) -> Data {
        var sample = Data()
        for nal in nals {
            let body = Data([nal.type << 1, 0x01] + [UInt8](repeating: 0xAB, count: nal.size))
            var length = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
            sample += body
        }
        return sample
    }

    /// A syntactically valid AC-3 syncframe header: 48 kHz, 3/2 mode + LFE,
    /// 448 kbps (frmsizecod 26), bsid 8. Only the fields dac3 reads are real.
    static var ac3Syncframe: Data {
        var writer = BitWriter()
        writer.write(0x0B77, 16) // syncword
        writer.write(0, 16) // crc1
        writer.write(0, 2) // fscod 48k
        writer.write(26, 6) // frmsizecod
        writer.write(8, 5) // bsid
        writer.write(0, 3) // bsmod
        writer.write(7, 3) // acmod 3/2
        writer.write(0, 2) // cmixlev
        writer.write(0, 2) // surmixlev
        writer.write(1, 1) // lfeon
        writer.write(0, 7) // pad to a byte boundary
        return writer.data
    }

    /// A dependent-substream BSI (strmtyp 1) declaring a custom channel map
    /// — the 7.1-and-up shape, where extra channels ride a dependent
    /// substream and `chanmap` says which.
    static func eac3DependentSyncframe(chanmap: Int, frameSizeWords: Int = 128) -> Data {
        var writer = BitWriter()
        writer.write(0x0B77, 16) // syncword
        writer.write(1, 2) // strmtyp dependent
        writer.write(0, 3) // substreamid
        writer.write(frameSizeWords - 1, 11) // frmsiz
        writer.write(0, 2) // fscod 48k
        writer.write(3, 2) // numblkscod 6 blocks
        writer.write(7, 3) // acmod 3/2
        writer.write(1, 1) // lfeon
        writer.write(16, 5) // bsid
        writer.write(0, 5) // dialnorm
        writer.write(0, 1) // compre
        writer.write(1, 1) // chanmape
        writer.write(chanmap, 16)
        writer.write(0, 7) // pad to a byte boundary
        var frame = writer.data
        frame += Data(count: frameSizeWords * 2 - frame.count)
        return frame
    }

    /// A syntactically valid E-AC-3 independent-substream BSI: 48 kHz,
    /// 6 blocks, 3/2 + LFE, bsid 16. `frameSizeWords` controls frmsiz.
    static func eac3Syncframe(frameSizeWords: Int = 512) -> Data {
        var writer = BitWriter()
        writer.write(0x0B77, 16) // syncword
        writer.write(0, 2) // strmtyp independent
        writer.write(0, 3) // substreamid
        writer.write(frameSizeWords - 1, 11) // frmsiz
        writer.write(0, 2) // fscod 48k
        writer.write(3, 2) // numblkscod 6 blocks
        writer.write(7, 3) // acmod 3/2
        writer.write(1, 1) // lfeon
        writer.write(16, 5) // bsid
        writer.write(0, 5) // dialnorm
        writer.write(0, 1) // compre
        writer.write(0, 5) // pad
        var frame = writer.data
        frame += Data(count: frameSizeWords * 2 - frame.count)
        return frame
    }
}

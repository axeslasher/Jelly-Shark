import Foundation

// The byte layout of a progressively-served remux (#172): a fixed map from
// byte ranges to fragments, computable from the Matroska index alone —
// before any cluster is read.
//
// The tension it resolves: HTTP Range support needs every fragment's byte
// offset up front, but a fragment's exact size is unknowable without
// remuxing it. So each cue-to-cue span gets a fixed byte budget (a "slot"):
// the span's source size — known exactly from consecutive cue offsets —
// plus margin for moof overhead. A remux can only shrink the payload (EBML
// framing is removed, the DV enhancement layer is dropped), so the budget
// holds, and the unreferenced tail of each `mdat` legally absorbs the
// slack. Padding bytes are zeros that exist only on the loopback wire.
//
// Layout: [init segment][sidx][slot 0][slot 1]…  The sidx is what lets
// AVPlayer seek by index — without it a seek scans moof headers, and every
// probe would cost a full span remux upstream.
public struct ProgressiveMP4Layout: Sendable {
    /// One fragment's byte budget and source span.
    public struct Slot: Sendable, Equatable {
        /// Absolute offset of this fragment in the served file.
        public let fileOffset: UInt64
        /// The fragment's fixed byte budget (moof + padded mdat).
        public let size: Int
        /// Source range: [clusterOffset, endBound) for the demuxer.
        public let clusterOffset: UInt64
        public let clusterEndBound: UInt64
        /// Cue time of this span and of the next (for last-sample duration).
        public let timeTicks: UInt64
        public let nextTimeTicks: Int64?
    }

    public enum LayoutError: Error, Equatable {
        /// A produced fragment exceeded its slot's budget — a margin bug,
        /// never expected in the field; the session must fail loudly rather
        /// than serve corrupt bytes.
        case slotOverflow(slot: Int, produced: Int, budget: Int)
    }

    public let initSegment: Data
    /// One `sidx` box per track, concatenated — see `segmentIndex`.
    public let sidx: Data
    public let slots: [Slot]
    /// Total size of the served file in bytes.
    public let totalSize: UInt64

    /// Build the layout from a loaded index. `timescale` and `trackIDs`
    /// (video first) must match what the init segment declares.
    public init(index: MatroskaIndex, initSegment: Data, timescale: Int, trackIDs: [Int]) {
        self.initSegment = initSegment

        // Slot budget: span bytes (the remux can only shrink the payload)
        // plus headroom for the moof — per-sample trun entries outgrow the
        // EBML block framing they replace only for heavily-laced audio, and
        // by a few KB per span at most; 64 KB is comfortably beyond it.
        var slots: [Slot] = []
        let cues = index.cues
        var provisional: [(span: Int, slot: Slot)] = []
        for (i, cue) in cues.enumerated() {
            let endBound = i + 1 < cues.count ? cues[i + 1].clusterOffset : index.segmentDataEnd
            let spanBytes = Int(endBound - cue.clusterOffset)
            let budget = spanBytes + spanBytes / 16 + 64 * 1024
            provisional.append((spanBytes, Slot(
                fileOffset: 0, // patched below, once the sidx size is known
                size: budget,
                clusterOffset: cue.clusterOffset,
                clusterEndBound: endBound,
                timeTicks: cue.timeTicks,
                nextTimeTicks: i + 1 < cues.count ? Int64(cues[i + 1].timeTicks) : nil,
            )))
        }

        // The sidx indexes every slot with its exact (budgeted) size, so its
        // own size depends only on the slot and track counts.
        let durationTicks = Int((index.durationTicks ?? 0).rounded())
        sidx = Self.segmentIndex(
            timescale: timescale,
            trackIDs: trackIDs,
            slots: provisional.map(\.slot),
            totalDurationTicks: durationTicks,
        )

        var offset = UInt64(initSegment.count + sidx.count)
        for entry in provisional {
            let slot = entry.slot
            slots.append(Slot(
                fileOffset: offset,
                size: slot.size,
                clusterOffset: slot.clusterOffset,
                clusterEndBound: slot.clusterEndBound,
                timeTicks: slot.timeTicks,
                nextTimeTicks: slot.nextTimeTicks,
            ))
            offset += UInt64(slot.size)
        }
        self.slots = slots
        totalSize = offset
    }

    // MARK: - Range mapping

    /// A piece of a served byte range.
    public enum Region: Equatable, Sendable {
        /// A subrange of the head (init segment + sidx, one contiguous blob).
        case head(Range<Int>)
        /// A subrange within slot `index`'s padded fragment bytes.
        case fragment(index: Int, subrange: Range<Int>)
    }

    /// The head blob: init segment followed by sidx.
    public var head: Data {
        initSegment + sidx
    }

    /// Decompose an absolute byte range into regions, clamped to the file.
    public func regions(for range: Range<UInt64>) -> [Region] {
        let clamped = range.clamped(to: 0 ..< totalSize)
        guard !clamped.isEmpty else { return [] }
        var regions: [Region] = []

        let headSize = UInt64(initSegment.count + sidx.count)
        if clamped.lowerBound < headSize {
            let end = min(clamped.upperBound, headSize)
            regions.append(.head(Int(clamped.lowerBound) ..< Int(end)))
        }

        // Slots are uniform only in construction, not size — binary search
        // the first overlapping slot by fileOffset.
        var low = 0
        var high = slots.count
        while low < high {
            let mid = (low + high) / 2
            if slots[mid].fileOffset + UInt64(slots[mid].size) <= clamped.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var index = low
        while index < slots.count, slots[index].fileOffset < clamped.upperBound {
            let slot = slots[index]
            let start = max(clamped.lowerBound, slot.fileOffset)
            let end = min(clamped.upperBound, slot.fileOffset + UInt64(slot.size))
            regions.append(.fragment(
                index: index,
                subrange: Int(start - slot.fileOffset) ..< Int(end - slot.fileOffset),
            ))
            index += 1
        }
        return regions
    }

    /// Pad a produced fragment (`moof` + `mdat`) to exactly fill its slot by
    /// extending the `mdat` with unreferenced zero bytes. Samples address
    /// into the mdat via moof-relative offsets, so a trailing tail the trun
    /// never references is legal padding.
    public func padded(fragment: Data, slot index: Int) throws -> Data {
        let budget = slots[index].size
        guard fragment.count <= budget else {
            throw LayoutError.slotOverflow(slot: index, produced: fragment.count, budget: budget)
        }
        let padding = budget - fragment.count
        guard padding > 0 else { return fragment }

        // The mdat is the final box; grow its size field by the padding.
        var output = fragment
        var offset = 0
        while offset + 8 <= output.count {
            let size = output.subdata(in: offset ..< offset + 4).reduce(0) { ($0 << 8) | Int($1) }
            let type = String(decoding: output.subdata(in: offset + 4 ..< offset + 8), as: UTF8.self)
            if type == "mdat" {
                let grown = UInt32(size + padding)
                output.replaceSubrange(offset ..< offset + 4, with: [
                    UInt8(grown >> 24), UInt8((grown >> 16) & 0xFF), UInt8((grown >> 8) & 0xFF), UInt8(grown & 0xFF),
                ])
                output.append(Data(count: padding))
                return output
            }
            guard size >= 8 else { break }
            offset += size
        }
        throw LayoutError.slotOverflow(slot: index, produced: fragment.count, budget: budget)
    }

    // MARK: - sidx

    /// One version-1 `sidx` per track, each indexing every slot with its
    /// exact (budgeted) size and cue-derived duration, so seeks jump
    /// straight to a fragment.
    ///
    /// Per-track boxes are load-bearing, not style: AVFoundation ignored a
    /// single track-independent `reference_ID = 1` sidx and fell back to
    /// scanning every moof over HTTP before readiness — a startup measured
    /// in tens of minutes on a long feature. ffmpeg's `global_sidx` shape
    /// (one sidx per track, actual track IDs, each `first_offset` skipping
    /// the sidx boxes after it) was honored under identical conditions:
    /// ready in seconds, a handful of requests. Mirror it exactly.
    private static func segmentIndex(timescale: Int, trackIDs: [Int], slots: [Slot], totalDurationTicks: Int) -> Data {
        func uint32(_ value: Int) -> Data {
            let v = UInt32(clamping: value)
            return Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        func uint64(_ value: UInt64) -> Data {
            Data((0 ..< 8).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
        }

        let boxSize = 40 + 12 * slots.count
        var output = Data()
        for (trackIndex, trackID) in trackIDs.enumerated() {
            var payload = Data([1, 0, 0, 0]) // version 1, flags 0
            payload += uint32(trackID) // reference_ID
            payload += uint32(timescale)
            payload += uint64(slots.first.map(\.timeTicks) ?? 0) // earliest_presentation_time
            // first_offset is anchored to the byte after THIS box; skip the
            // remaining sidx boxes so every track's index lands on moof 0.
            payload += uint64(UInt64((trackIDs.count - 1 - trackIndex) * boxSize))
            payload += Data([0, 0]) // reserved
            payload += Data([UInt8(slots.count >> 8), UInt8(slots.count & 0xFF)])
            for slot in slots {
                payload += uint32(slot.size) // reference_type 0 (media) + size
                let duration: Int = if let next = slot.nextTimeTicks {
                    Int(next) - Int(slot.timeTicks)
                } else {
                    max(totalDurationTicks - Int(slot.timeTicks), 0)
                }
                payload += uint32(duration)
                payload += uint32(0x8000_0000) // starts_with_SAP, type unknown
            }
            output += uint32(8 + payload.count) + Data("sidx".utf8) + payload
        }
        return output
    }
}

import Foundation
@testable import JellyfinKit
import Testing

@Suite("ProgressiveMP4Layout")
struct ProgressiveMP4LayoutTests {
    /// Layout over the real ffmpeg fixture: index, init segment, remuxer.
    private func makeLayout() async throws -> (MatroskaDemuxer, MatroskaFMP4Remuxer, ProgressiveMP4Layout) {
        let url = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: url)))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)
        let firstEnd = index.cues.count > 1 ? index.cues[1].clusterOffset : index.segmentDataEnd
        let firstSpan = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: firstEnd)
        let initSegment = try remuxer.makeInitializationSegment(firstCluster: firstSpan)
        let layout = ProgressiveMP4Layout(index: index, initSegment: initSegment, timescale: remuxer.timescale)
        return (demuxer, remuxer, layout)
    }

    @Test("Slots tile the file contiguously after the head")
    func slotsAreContiguous() async throws {
        let (_, _, layout) = try await makeLayout()
        var expected = UInt64(layout.initSegment.count + layout.sidx.count)
        for slot in layout.slots {
            #expect(slot.fileOffset == expected)
            expected += UInt64(slot.size)
        }
        #expect(layout.totalSize == expected)
    }

    @Test("The sidx indexes every slot with its exact budgeted size")
    func sidxShape() async throws {
        let (_, _, layout) = try await makeLayout()
        let boxes = MP4Box.parse(layout.sidx)
        #expect(boxes.count == 1)
        #expect(boxes[0].type == "sidx")

        let payload = [UInt8](boxes[0].payload)
        #expect(payload[0] == 1) // version
        // version/flags(4) + reference_ID(4) + timescale(4) + EPT(8) +
        // first_offset(8) + reserved(2), then reference_count(2).
        let referenceCount = Int(payload[30]) << 8 | Int(payload[31])
        #expect(referenceCount == layout.slots.count)
        for (i, slot) in layout.slots.enumerated() {
            let entry = 32 + i * 12
            let size = payload[entry ..< entry + 4].reduce(0) { ($0 << 8) | Int($1) }
            #expect(size == slot.size)
        }
    }

    @Test("Region mapping decomposes ranges across head and fragments")
    func regionMapping() async throws {
        let (_, _, layout) = try await makeLayout()
        let headSize = UInt64(layout.initSegment.count + layout.sidx.count)
        let firstSlot = layout.slots[0]

        // A range straddling head end and fragment 0 start.
        let straddle = layout.regions(for: headSize - 10 ..< headSize + 20)
        #expect(straddle == [
            .head(Int(headSize) - 10 ..< Int(headSize)),
            .fragment(index: 0, subrange: 0 ..< 20),
        ])

        // A range fully inside fragment 1.
        if layout.slots.count > 1 {
            let second = layout.slots[1]
            let inside = layout.regions(for: second.fileOffset + 5 ..< second.fileOffset + 25)
            #expect(inside == [.fragment(index: 1, subrange: 5 ..< 25)])
        }

        // A range crossing a slot boundary.
        let boundary = firstSlot.fileOffset + UInt64(firstSlot.size)
        if layout.slots.count > 1 {
            let crossing = layout.regions(for: boundary - 8 ..< boundary + 8)
            #expect(crossing == [
                .fragment(index: 0, subrange: firstSlot.size - 8 ..< firstSlot.size),
                .fragment(index: 1, subrange: 0 ..< 8),
            ])
        }

        // Past EOF clamps to nothing.
        #expect(layout.regions(for: layout.totalSize ..< layout.totalSize + 100).isEmpty)
    }

    @Test("Padding extends the mdat to exactly fill the slot")
    func paddingFillsSlot() async throws {
        let (demuxer, remuxer, layout) = try await makeLayout()
        let slot = layout.slots[0]
        let span = try await demuxer.readClusters(from: slot.clusterOffset, to: slot.clusterEndBound)
        let fragment = try remuxer.makeFragment(sequence: 1, cluster: span, nextClusterTimeTicks: slot.nextTimeTicks)
        let padded = try layout.padded(fragment: fragment, slot: 0)

        #expect(padded.count == slot.size)
        let boxes = MP4Box.parse(padded)
        #expect(boxes.map(\.type) == ["moof", "mdat"])
        // The pad is a tail of the mdat, invisible to the box walk.
        #expect(boxes[1].payload.count == slot.size - (boxes[0].payload.count + 8) - 8)
    }

    @Test("A fragment over budget is refused, never truncated")
    func overflowRefused() async throws {
        let (_, _, layout) = try await makeLayout()
        let oversized = Data(count: layout.slots[0].size + 1)
        #expect(throws: ProgressiveMP4Layout.LayoutError.self) {
            _ = try layout.padded(fragment: oversized, slot: 0)
        }
    }

    @Test("The materialized virtual file is structurally a valid fMP4")
    func materializedFile() async throws {
        let (demuxer, remuxer, layout) = try await makeLayout()
        var file = layout.head
        for (i, slot) in layout.slots.enumerated() {
            let span = try await demuxer.readClusters(from: slot.clusterOffset, to: slot.clusterEndBound)
            let fragment = try remuxer.makeFragment(sequence: i + 1, cluster: span, nextClusterTimeTicks: slot.nextTimeTicks)
            file += try layout.padded(fragment: fragment, slot: i)
        }
        #expect(UInt64(file.count) == layout.totalSize)

        let types = MP4Box.parse(file).map(\.type)
        #expect(types.prefix(3) == ["ftyp", "moov", "sidx"])
        #expect(Array(types.dropFirst(3)) == Array(repeating: ["moof", "mdat"], count: layout.slots.count).flatMap(\.self))
    }
}

import Foundation
@testable import JellyfinKit
import Testing

@Suite("MatroskaDemuxer")
struct MatroskaDemuxerTests {
    private func videoTrack(number: Int = 1) -> MatroskaFixtureBuilder.Track {
        MatroskaFixtureBuilder.Track(
            number: number,
            type: 1,
            codecID: "V_MPEGH/ISO/HEVC",
            codecPrivate: CodecFixtures.hvcC,
            defaultDurationNs: 41_666_666,
            width: 640,
            height: 360,
        )
    }

    private func audioTrack(number: Int = 2, codecID: String = "A_AC3") -> MatroskaFixtureBuilder.Track {
        MatroskaFixtureBuilder.Track(
            number: number,
            type: 2,
            codecID: codecID,
            channels: 6,
            samplingFrequency: 48000,
        )
    }

    private func simpleFixture() -> MatroskaFixtureBuilder {
        var builder = MatroskaFixtureBuilder()
        builder.tracks = [videoTrack(), audioTrack()]
        builder.clusters = [
            MatroskaFixtureBuilder.Cluster(timestamp: 0, blocks: [
                .init(track: 1, relativeTime: 0, keyframe: true, framePayloads: [Data(repeating: 0x11, count: 64)]),
                .init(track: 2, relativeTime: 5, keyframe: true, framePayloads: [Data(repeating: 0x22, count: 32)]),
            ]),
            MatroskaFixtureBuilder.Cluster(timestamp: 4000, blocks: [
                .init(track: 1, relativeTime: 0, keyframe: true, framePayloads: [Data(repeating: 0x33, count: 48)]),
            ]),
        ]
        return builder
    }

    // MARK: - Index

    @Test("Index parses Info, Tracks, and Cues from the head")
    func indexFromHead() async throws {
        let demuxer = MatroskaDemuxer(source: DataByteSource(simpleFixture().build()))
        let index = try await demuxer.loadIndex()

        #expect(index.timestampScaleNs == 1_000_000)
        #expect(index.durationTicks == 8000)
        #expect(index.tracks.count == 2)
        #expect(index.tracks[0].codecID == "V_MPEGH/ISO/HEVC")
        #expect(index.tracks[0].codecPrivate == CodecFixtures.hvcC)
        #expect(index.tracks[0].defaultDurationNs == 41_666_666)
        #expect(index.tracks[0].pixelWidth == 640)
        #expect(index.tracks[1].type == .audio)
        #expect(index.tracks[1].channels == 6)
        #expect(index.cues.count == 2)
        #expect(index.cues[0].timeTicks == 0)
        #expect(index.cues[1].timeTicks == 4000)
    }

    @Test("Index follows a SeekHead to Cues stored after the clusters")
    func indexViaSeekHead() async throws {
        var builder = simpleFixture()
        builder.cuesAtEnd = true
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()

        #expect(index.cues.count == 2)
        // Cue offsets must land exactly on Cluster elements.
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.cues[1].clusterOffset)
        #expect(cluster.frames.count == 2)
    }

    @Test("A file without Cues is refused as unseekable")
    func missingCuesRefused() async throws {
        var builder = simpleFixture()
        builder.includeCues = false
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        await #expect(throws: MatroskaError.unseekable) {
            _ = try await demuxer.loadIndex()
        }
    }

    @Test("Non-Matroska data is rejected up front")
    func notMatroska() async throws {
        let demuxer = MatroskaDemuxer(source: DataByteSource(Data(repeating: 0x42, count: 1024)))
        await #expect(throws: MatroskaError.notMatroska) {
            _ = try await demuxer.loadIndex()
        }
    }

    // MARK: - Clusters and blocks

    @Test("Cluster blocks carry track, time, and keyframe flags")
    func clusterBlocks() async throws {
        let demuxer = MatroskaDemuxer(source: DataByteSource(simpleFixture().build()))
        let index = try await demuxer.loadIndex()
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.cues[1].clusterOffset)

        #expect(cluster.timestampTicks == 0)
        #expect(cluster.frames.count == 2)
        #expect(cluster.frames[0].trackNumber == 1)
        #expect(cluster.frames[0].isKeyframe)
        #expect(cluster.frames[1].trackNumber == 2)
        #expect(cluster.frames[1].timeTicks == 5)
        #expect(cluster.frames[1].data == Data(repeating: 0x22, count: 32))
    }

    @Test("Negative relative block time resolves against the cluster timestamp")
    func negativeRelativeTime() async throws {
        var builder = simpleFixture()
        builder.clusters[1].blocks = [
            .init(track: 1, relativeTime: -100, keyframe: true, framePayloads: [Data(repeating: 0x44, count: 16)]),
        ]
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let cluster = try await demuxer.readClusters(from: index.cues[1].clusterOffset, to: index.segmentDataEnd)

        #expect(cluster.frames[0].timeTicks == 3900)
    }

    @Test("BlockGroup keyframe status comes from ReferenceBlock, not flags")
    func blockGroupKeyframes() async throws {
        var builder = simpleFixture()
        builder.clusters = [
            MatroskaFixtureBuilder.Cluster(timestamp: 0, blocks: [
                .init(track: 1, relativeTime: 0, keyframe: false, framePayloads: [Data(repeating: 0x01, count: 8)], asBlockGroup: true),
                .init(track: 1, relativeTime: 40, keyframe: false, framePayloads: [Data(repeating: 0x02, count: 8)], asBlockGroup: true, referenceBlock: -40),
            ]),
        ]
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.segmentDataEnd)

        #expect(cluster.frames[0].isKeyframe)
        #expect(!cluster.frames[1].isKeyframe)
    }

    // MARK: - Lacing

    @Test("Xiph lacing splits frames, including 255-run sizes")
    func xiphLacing() async throws {
        let payloads = [
            Data(repeating: 0xA1, count: 300), // encodes as 255 + 45
            Data(repeating: 0xA2, count: 40),
            Data(repeating: 0xA3, count: 77),
        ]
        try await assertLacedFrames(payloads, mode: .xiph)
    }

    @Test("Fixed lacing splits the payload evenly")
    func fixedLacing() async throws {
        let payloads = (0 ..< 4).map { Data(repeating: UInt8(0xB0 + $0), count: 25) }
        try await assertLacedFrames(payloads, mode: .fixed)
    }

    @Test("EBML lacing decodes signed size deltas")
    func ebmlLacing() async throws {
        let payloads = [
            Data(repeating: 0xC1, count: 480),
            Data(repeating: 0xC2, count: 120), // delta -360
            Data(repeating: 0xC3, count: 511), // delta +391
            Data(repeating: 0xC4, count: 77),
        ]
        try await assertLacedFrames(payloads, mode: .ebml)
    }

    @Test("Only the first laced frame inherits the keyframe flag")
    func lacedKeyframeIsFirstFrameOnly() async throws {
        var builder = simpleFixture()
        builder.clusters = [
            MatroskaFixtureBuilder.Cluster(timestamp: 0, blocks: [
                .init(track: 2, relativeTime: 0, keyframe: true, framePayloads: [
                    Data(repeating: 0xD1, count: 10), Data(repeating: 0xD2, count: 10),
                ], lacing: .fixed),
            ]),
        ]
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.segmentDataEnd)

        #expect(cluster.frames.map(\.isKeyframe) == [true, false])
        #expect(cluster.frames.map(\.laceIndex) == [0, 1])
        #expect(cluster.frames.map(\.laceCount) == [2, 2])
    }

    private func assertLacedFrames(_ payloads: [Data], mode: MatroskaFixtureBuilder.Lacing) async throws {
        var builder = simpleFixture()
        builder.clusters = [
            MatroskaFixtureBuilder.Cluster(timestamp: 0, blocks: [
                .init(track: 2, relativeTime: 0, keyframe: true, framePayloads: payloads, lacing: mode),
            ]),
        ]
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.segmentDataEnd)

        #expect(cluster.frames.count == payloads.count)
        #expect(cluster.frames.map(\.data) == payloads)
        #expect(cluster.frames.allSatisfy { $0.timeTicks == 0 })
    }

    // MARK: - Track metadata

    @Test("A block from track 127 parses despite the all-ones VINT encoding")
    func track127Block() throws {
        // Hand-built because EBMLWriter.vint never emits all-ones: track 127
        // minimally encoded is exactly 0xFF, a legal value here — the
        // unknown-size rule is for element sizes only (RFC 8794 vs 9559).
        var body = Data([0xFF]) // track 127
        body += Data([0x00, 0x00]) // relative time
        body += Data([0x80]) // flags: keyframe, no lacing
        body += Data(repeating: 0x11, count: 16)
        let payload = EBMLWriter.uintElement(MatroskaID.clusterTimestamp, 0)
            + EBMLWriter.element(MatroskaID.simpleBlock, body)
        let cluster = try MatroskaDemuxer.parseCluster(payload)
        #expect(cluster.frames.count == 1)
        #expect(cluster.frames.first?.trackNumber == 127)
    }

    @Test("An EBML lace whose first frame is 127 bytes parses")
    func ebmlLaceOf127Bytes() throws {
        let first = Data(repeating: 0xAA, count: 127)
        let second = Data(repeating: 0xBB, count: 5)
        var body = Data([0x81]) // track 1
        body += Data([0x00, 0x00]) // relative time
        body += Data([0x86]) // flags: keyframe, EBML lacing
        body += Data([1]) // frame count - 1
        body += Data([0xFF]) // first lace size: 127, minimal all-ones form
        body += first + second
        let payload = EBMLWriter.uintElement(MatroskaID.clusterTimestamp, 0)
            + EBMLWriter.element(MatroskaID.simpleBlock, body)
        let cluster = try MatroskaDemuxer.parseCluster(payload)
        #expect(cluster.frames.map(\.data) == [first, second])
    }

    @Test("A cluster header straddling the span bound throws, not traps")
    func clusterHeaderOverrunsSpan() async throws {
        let demuxer = MatroskaDemuxer(source: DataByteSource(simpleFixture().build()))
        let index = try await demuxer.loadIndex()
        let offset = try #require(index.cues.first?.clusterOffset)
        // A bound inside the cluster's own header — the corrupt-cue shape:
        // contentStart lands past endBound, and the span math must refuse
        // it rather than underflow.
        await #expect(throws: MatroskaError.self) {
            _ = try await demuxer.readClusters(from: offset, to: offset + 4)
        }
    }

    @Test("A sized non-Cluster element mid-span is skipped, not a truncation")
    func interiorVoidSkipped() async throws {
        /// An in-place edit (mkvpropedit tag rewrite) leaves a Void between
        /// clusters. A merged multi-cue span (#99) must include the clusters
        /// behind it — breaking at the Void would serve a segment far shorter
        /// than its declared EXTINF, with no error anywhere.
        func cluster(timestamp: UInt64, fill: UInt8) -> Data {
            var body = Data([0x81]) // track 1
            body += Data([0x00, 0x00]) // relative time
            body += Data([0x80]) // flags: keyframe, no lacing
            body += Data(repeating: fill, count: 16)
            return EBMLWriter.element(
                MatroskaID.cluster,
                EBMLWriter.uintElement(MatroskaID.clusterTimestamp, timestamp)
                    + EBMLWriter.element(MatroskaID.simpleBlock, body),
            )
        }
        let void = EBMLWriter.element(0xEC, Data(count: 32)) // Void
        let span = cluster(timestamp: 0, fill: 0x11) + void + cluster(timestamp: 2000, fill: 0x22)
        let demuxer = MatroskaDemuxer(source: DataByteSource(span))
        let merged = try await demuxer.readClusters(from: 0, to: UInt64(span.count))
        #expect(merged.frames.count == 2)
        #expect(merged.frames.last?.timeTicks == 2000)
    }

    @Test("BlockAdditionMapping surfaces the Dolby Vision configuration")
    func dolbyVisionMapping() async throws {
        let dvcC = DolbyVisionConfiguration(
            profile: 7,
            level: 6,
            rpuPresent: true,
            elPresent: true,
            blPresent: true,
            blSignalCompatibilityID: 6,
        )
        var builder = simpleFixture()
        builder.tracks[0].additionMappings = [("dvcC", dvcC.boxData())]
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()

        let parsed = index.tracks[0].dolbyVisionConfiguration
        #expect(parsed == dvcC)
    }

    // MARK: - Real ffmpeg-muxed file

    @Test("End to end against a real ffmpeg mux (HEVC Main 10 + AC-3)")
    func ffmpegFixture() async throws {
        let url = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: url)))
        let index = try await demuxer.loadIndex()

        #expect(index.timestampScaleNs == 1_000_000)
        #expect(abs((index.durationSeconds ?? 0) - 8.0) < 0.1)

        let video = try #require(index.tracks.first { $0.type == .video })
        #expect(video.codecID == "V_MPEGH/ISO/HEVC")
        // Spike finding 1: CodecPrivate is the hvcC record itself.
        let codecPrivate = try #require(video.codecPrivate)
        #expect(codecPrivate[codecPrivate.startIndex] == 1) // configurationVersion
        let audio = try #require(index.tracks.first { $0.type == .audio })
        #expect(audio.codecID == "A_AC3")

        #expect(!index.cues.isEmpty)

        // Every cue must land on a parseable cluster; count all the frames.
        var videoFrames = 0
        var keyframes = 0
        for (i, cue) in index.cues.enumerated() {
            let endBound = i + 1 < index.cues.count ? index.cues[i + 1].clusterOffset : index.segmentDataEnd
            let cluster = try await demuxer.readClusters(from: cue.clusterOffset, to: endBound)
            let frames = cluster.frames.filter { $0.trackNumber == video.number }
            videoFrames += frames.count
            keyframes += frames.filter(\.isKeyframe).count
            for frame in frames {
                // Spike finding 2: frames are length-prefixed NALUs — the
                // filter parsing them cleanly proves the prefixes are sound.
                #expect(HEVCNALFilter.droppingEnhancementLayer(from: frame.data, lengthSize: 4) != nil)
            }
        }
        // Span reading must cover every cluster, cued or not: all 8s x 24fps.
        #expect(videoFrames == 192)
        #expect(keyframes >= 4) // keyint 48 at 24fps, plus any scene cuts
    }
}

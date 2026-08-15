import Foundation
@testable import JellyfinKit
import Testing

// MARK: - Dolby Vision

@Suite("DolbyVisionConfiguration")
struct DolbyVisionConfigurationTests {
    private let profile7 = DolbyVisionConfiguration(
        profile: 7,
        level: 6,
        rpuPresent: true,
        elPresent: true,
        blPresent: true,
        blSignalCompatibilityID: 6,
    )

    @Test("Record round-trips through its box form")
    func boxRoundTrip() {
        let box = profile7.boxData()
        #expect(box.count == 32) // 8 header + 24 record
        #expect(String(decoding: box.subdata(in: 4 ..< 8), as: UTF8.self) == "dvcC")
        #expect(DolbyVisionConfiguration(recordOrBox: box) == profile7)
        // And from the bare record, as some muxes store it.
        #expect(DolbyVisionConfiguration(recordOrBox: box.dropFirst(8)) == profile7)
    }

    @Test("Profile 8 uses the dvvC box type")
    func profile8Box() {
        let config = DolbyVisionConfiguration(profile: 8, level: 6, rpuPresent: true, elPresent: false, blPresent: true, blSignalCompatibilityID: 1)
        let box = config.boxData()
        #expect(String(decoding: box.subdata(in: 4 ..< 8), as: UTF8.self) == "dvvC")
    }

    /// Device-measured 2026-08-11: signalling profile 7 as 8.1 leaves the
    /// source's dual-layer RPU describing a reconstruction the stripped
    /// stream can no longer perform, and every profile-7 source rendered as
    /// chroma garbage. Unsignalled serves the HDR10 base layer instead.
    @Test("Profile 7 is unsignalled, but still has its EL stripped")
    func profile7IsUnsignalled() {
        #expect(profile7.signalledForAVFoundation() == nil)
        #expect(profile7.requiresEnhancementLayerFilter)
    }

    @Test("Profiles 5 and 8 pass through; unknown profiles are unsignalled")
    func passthroughAndRefusal() {
        let profile8 = DolbyVisionConfiguration(profile: 8, level: 6, rpuPresent: true, elPresent: false, blPresent: true, blSignalCompatibilityID: 1)
        #expect(profile8.signalledForAVFoundation() == profile8)
        #expect(!profile8.requiresEnhancementLayerFilter)

        let profile4 = DolbyVisionConfiguration(profile: 4, level: 6, rpuPresent: true, elPresent: true, blPresent: true, blSignalCompatibilityID: 2)
        #expect(profile4.signalledForAVFoundation() == nil)
    }
}

@Suite("HEVCNALFilter")
struct HEVCNALFilterTests {
    @Test("Drops UNSPEC63 enhancement layer, keeps the UNSPEC62 RPU")
    func dropsEnhancementLayerOnly() throws {
        let sample = CodecFixtures.hevcAccessUnit([
            (type: 35, size: 4), // AUD
            (type: 20, size: 900), // IRAP slice
            (type: 63, size: 40), // enhancement layer — must go
            (type: 62, size: 60), // RPU — must stay
        ])
        let filtered = try #require(HEVCNALFilter.droppingEnhancementLayer(from: sample, lengthSize: 4))

        let kept = CodecFixtures.hevcAccessUnit([
            (type: 35, size: 4),
            (type: 20, size: 900),
            (type: 62, size: 60),
        ])
        #expect(filtered == kept)
    }

    @Test("Passes through samples with no enhancement layer untouched")
    func passthrough() {
        let sample = CodecFixtures.hevcAccessUnit([(type: 32, size: 20), (type: 1, size: 500)])
        #expect(HEVCNALFilter.droppingEnhancementLayer(from: sample, lengthSize: 4) == sample)
    }

    @Test("Honours non-4-byte length prefixes")
    func lengthPrefixWidth() throws {
        // Two NALUs with 2-byte prefixes: type 1 kept, type 63 dropped.
        var sample = Data([0x00, 0x04, 0x02, 0x01, 0xAA, 0xBB])
        sample += Data([0x00, 0x03, 0x7E, 0x01, 0xCC])
        let filtered = try #require(HEVCNALFilter.droppingEnhancementLayer(from: sample, lengthSize: 2))
        #expect(filtered == Data([0x00, 0x04, 0x02, 0x01, 0xAA, 0xBB]))
    }

    @Test("Malformed length prefixes are refused, not passed through")
    func malformedRefused() {
        // Length claims 200 bytes; only 4 present.
        let sample = Data([0x00, 0x00, 0x00, 0xC8, 0x02, 0x01, 0xAA, 0xBB])
        #expect(HEVCNALFilter.droppingEnhancementLayer(from: sample, lengthSize: 4) == nil)
    }
}

// MARK: - Audio configuration

@Suite("AudioSampleEntryConfiguration")
struct AudioCodecConfigurationTests {
    @Test("AC-3 dac3 is synthesized from the first syncframe")
    func dac3() throws {
        let track = MatroskaTrack(number: 2, type: .audio, codecID: "A_AC3")
        let config = try #require(AudioSampleEntryConfiguration.make(for: track, firstFrame: CodecFixtures.ac3Syncframe))
        #expect(config.entryType == "ac-3")
        #expect(String(decoding: config.configurationBox.subdata(in: 4 ..< 8), as: UTF8.self) == "dac3")

        // fscod 0, bsid 8, bsmod 0, acmod 7, lfeon 1, bit_rate_code 13:
        // 00 01000 000 111 1 01101 00000 -> 0x10 0x3D 0xA0
        #expect([UInt8](config.configurationBox.dropFirst(8)) == [0x10, 0x3D, 0xA0])
    }

    @Test("E-AC-3 dec3 declares the independent substream")
    func dec3() throws {
        let track = MatroskaTrack(number: 2, type: .audio, codecID: "A_EAC3")
        let config = try #require(AudioSampleEntryConfiguration.make(for: track, firstFrame: CodecFixtures.eac3Syncframe()))
        #expect(config.entryType == "ec-3")
        #expect(String(decoding: config.configurationBox.subdata(in: 4 ..< 8), as: UTF8.self) == "dec3")

        let payload = [UInt8](config.configurationBox.dropFirst(8))
        // 512-word frames, 6 blocks at 48 kHz: 512*16*48000/(6*256) = 256 kbps
        let dataRate = (Int(payload[0]) << 5) | (Int(payload[1]) >> 3)
        #expect(dataRate == 256)
        #expect(payload[1] & 0x07 == 0) // num_ind_sub == 0 (one substream)
        // fscod 0, bsid 16, then asvc/bsmod 0, acmod 7, lfeon 1, no dependents
        #expect(payload[2] == 0b0010_0000)
        #expect(payload[3] == 0b0000_1111)
        #expect(payload[4] == 0)
    }

    @Test("dec3 chan_loc maps the dependent substream's chanmap per Annex F")
    func dec3ChanLoc() throws {
        // The two fields run in opposite bit orders and chan_loc skips the
        // reserved chanmap bit, so a shift-and-mask cannot relate them: a
        // 7.1 source (chanmap bit 9, Lrs/Rrs) must land on chan_loc bit 1 —
        // not bit 7 (Cvh, a top-front-center channel).
        #expect(AudioSampleEntryConfiguration.chanLoc(fromChanmap: 0x0200) == 0x002) // Lrs/Rrs
        #expect(AudioSampleEntryConfiguration.chanLoc(fromChanmap: 0x0400) == 0x001) // Lc/Rc
        #expect(AudioSampleEntryConfiguration.chanLoc(fromChanmap: 0x0002) == 0x100) // LFE2
        #expect(AudioSampleEntryConfiguration.chanLoc(fromChanmap: 0x0004) == 0) // reserved bit
        #expect(AudioSampleEntryConfiguration.chanLoc(fromChanmap: 0xF801) == 0) // 5.1 + LFE bits

        // End to end: independent 5.1 + a dependent substream carrying the
        // rear pair, the plain E-AC-3 7.1 shape.
        let track = MatroskaTrack(number: 2, type: .audio, codecID: "A_EAC3")
        let sample = CodecFixtures.eac3Syncframe() + CodecFixtures.eac3DependentSyncframe(chanmap: 0x0200)
        let config = try #require(AudioSampleEntryConfiguration.make(for: track, firstFrame: sample))
        let payload = [UInt8](config.configurationBox.dropFirst(8))
        // reserved 000, num_dep_sub 0001, then chan_loc's 9 bits
        #expect(payload[4] == 0b0000_0010)
        #expect(payload[5] == 0b0000_0010)
    }

    @Test("AAC CodecPrivate is wrapped in an esds descriptor chain")
    func esds() throws {
        let asc = Data([0x11, 0x90]) // AAC-LC 48 kHz stereo
        let track = MatroskaTrack(number: 2, type: .audio, codecID: "A_AAC", codecPrivate: asc)
        let config = try #require(AudioSampleEntryConfiguration.make(for: track, firstFrame: nil))
        #expect(config.entryType == "mp4a")
        #expect(String(decoding: config.configurationBox.subdata(in: 4 ..< 8), as: UTF8.self) == "esds")
        // The AudioSpecificConfig must appear verbatim inside the chain.
        #expect(config.configurationBox.range(of: asc) != nil)
    }

    @Test("FLAC CodecPrivate becomes dfLa without the stream magic")
    func dfLa() throws {
        var streamInfo = Data([0x80, 0x00, 0x00, 0x22]) // last-block flag, type 0, length 34
        streamInfo += Data(repeating: 0x5A, count: 34)
        let codecPrivate = Data("fLaC".utf8) + streamInfo
        let track = MatroskaTrack(number: 2, type: .audio, codecID: "A_FLAC", codecPrivate: codecPrivate)
        let config = try #require(AudioSampleEntryConfiguration.make(for: track, firstFrame: nil))
        #expect(config.entryType == "fLaC")
        #expect(config.configurationBox.suffix(streamInfo.count) == streamInfo)
        #expect(config.configurationBox.range(of: Data("fLaC".utf8)) == nil)
    }

    @Test("Codecs the remux cannot carry are refused")
    func unsupportedRefused() {
        let truehd = MatroskaTrack(number: 2, type: .audio, codecID: "A_TRUEHD")
        #expect(AudioSampleEntryConfiguration.make(for: truehd, firstFrame: Data(count: 64)) == nil)
    }
}

// MARK: - FMP4Muxer

@Suite("FMP4Muxer")
struct FMP4MuxerTests {
    private var videoTrack: FMP4Muxer.VideoTrack {
        FMP4Muxer.VideoTrack(
            trackID: 1,
            codec: .hevc(hvcC: CodecFixtures.hvcC, dolbyVision: DolbyVisionConfiguration(
                profile: 8, level: 6, rpuPresent: true, elPresent: false, blPresent: true, blSignalCompatibilityID: 1,
            )),
            width: 3840,
            height: 2160,
        )
    }

    private var audioTrack: FMP4Muxer.AudioTrack {
        FMP4Muxer.AudioTrack(
            trackID: 2,
            configuration: AudioSampleEntryConfiguration.make(
                for: MatroskaTrack(number: 2, type: .audio, codecID: "A_EAC3"),
                firstFrame: CodecFixtures.eac3Syncframe(),
            )!,
            channelCount: 6,
            sampleRate: 48000,
        )
    }

    @Test("Init segment: ftyp + moov with a trak and trex per track")
    func initSegmentStructure() {
        let segment = FMP4Muxer.initializationSegment(video: videoTrack, audio: audioTrack, timescale: 1000)

        #expect(MP4Box.parse(segment).map(\.type) == ["ftyp", "moov"])
        #expect(MP4Box.findAll("moov/trak", in: segment).count == 2)
        #expect(MP4Box.findAll("moov/mvex/trex", in: segment).count == 2)
        // No duration anywhere in the moov — not even mehd. The sidx is the
        // only place duration lives; answering it here makes AVFoundation
        // skip the sidx and scan every moof over HTTP (2026-08-02 device
        // round).
        #expect(MP4Box.find("moov/mvex/mehd", in: segment) == nil)
    }

    @Test("hvc1 sample entry carries the hvcC record and the dvvC box")
    func hevcSampleEntry() throws {
        let segment = FMP4Muxer.initializationSegment(video: videoTrack, audio: nil, timescale: 1000)
        let stsd = try #require(MP4Box.find("moov/trak/mdia/minf/stbl/stsd", in: segment))
        let hvc1 = try #require(MP4Box.parse(stsd.payload.dropFirst(8)).first)
        #expect(hvc1.type == "hvc1")

        // Child boxes start after the 78-byte visual sample entry prefix.
        let children = MP4Box.parse(hvc1.payload.dropFirst(78))
        #expect(children.map(\.type) == ["hvcC", "dvvC"])
        #expect(children[0].payload == CodecFixtures.hvcC)
    }

    @Test("Audio sample entry uses the configuration's type and box")
    func audioSampleEntry() throws {
        let segment = FMP4Muxer.initializationSegment(video: nil, audio: audioTrack, timescale: 1000)
        let stsd = try #require(MP4Box.find("moov/trak/mdia/minf/stbl/stsd", in: segment))
        let entry = try #require(MP4Box.parse(stsd.payload.dropFirst(8)).first)
        #expect(entry.type == "ec-3")
        let children = MP4Box.parse(entry.payload.dropFirst(28))
        #expect(children.map(\.type) == ["dec3"])
    }

    @Test("Sample rates past 16 bits write a zero 16.16 field, not garbage")
    func hiResSampleRate() throws {
        func rateField(sampleRate: Int) throws -> Int {
            let track = FMP4Muxer.AudioTrack(
                trackID: 2,
                configuration: AudioSampleEntryConfiguration(entryType: "fLaC", configurationBox: Data()),
                channelCount: 2,
                sampleRate: sampleRate,
            )
            let segment = FMP4Muxer.initializationSegment(video: nil, audio: track, timescale: 1000)
            let stsd = try #require(MP4Box.find("moov/trak/mdia/minf/stbl/stsd", in: segment))
            let entry = try #require(MP4Box.parse(stsd.payload.dropFirst(8)).first)
            return entry.payload.dropFirst(24).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        }
        #expect(try rateField(sampleRate: 48000) == 48000 << 16)
        // 96 kHz cannot be represented; ffmpeg writes 0 and the true rate
        // rides the codec config. Clamping wrote 0xFFFFFFFF here.
        #expect(try rateField(sampleRate: 96000) == 0)
    }

    @Test("Media segment data offsets point at each track's mdat region")
    func mediaSegmentOffsets() throws {
        let videoData = Data(repeating: 0xEE, count: 100)
        let audioData = Data(repeating: 0xAF, count: 40)
        let segment = FMP4Muxer.mediaSegment(sequence: 3, fragments: [
            FMP4Muxer.TrackFragment(
                trackID: 1,
                baseDecodeTime: 4000,
                samples: [FMP4Muxer.Sample(duration: 40, size: 100, isSync: true, compositionOffset: 0)],
                data: videoData,
                isVideo: true,
            ),
            FMP4Muxer.TrackFragment(
                trackID: 2,
                baseDecodeTime: 4005,
                samples: [FMP4Muxer.Sample(duration: 32, size: 40, isSync: true)],
                data: audioData,
                isVideo: false,
            ),
        ])

        let boxes = MP4Box.parse(segment)
        #expect(boxes.map(\.type) == ["moof", "mdat"])
        #expect(boxes[1].payload == videoData + audioData)

        let moofSize = boxes[0].payload.count + 8
        let trafs = MP4Box.findAll("moof/traf", in: segment)
        #expect(trafs.count == 2)

        /// trun data_offset lives 4 bytes past the fullbox header + count.
        func dataOffset(_ traf: MP4Box) throws -> Int {
            let trun = try #require(traf.children.first { $0.type == "trun" })
            return trun.payload.subdata(in: 8 ..< 12).reduce(0) { ($0 << 8) | Int($1) }
        }
        // Video data starts right after moof + mdat header; audio follows it.
        #expect(try dataOffset(trafs[0]) == moofSize + 8)
        #expect(try dataOffset(trafs[1]) == moofSize + 8 + videoData.count)

        let mfhd = try #require(MP4Box.find("moof/mfhd", in: segment))
        #expect(mfhd.payload.suffix(4).reduce(0) { ($0 << 8) | Int($1) } == 3)
    }

    @Test("Video trun is version 1 with per-sample flags and signed offsets")
    func videoTrunShape() throws {
        let segment = FMP4Muxer.mediaSegment(sequence: 1, fragments: [
            FMP4Muxer.TrackFragment(
                trackID: 1,
                baseDecodeTime: 0,
                samples: [
                    FMP4Muxer.Sample(duration: 40, size: 10, isSync: true, compositionOffset: 0),
                    FMP4Muxer.Sample(duration: 40, size: 10, isSync: false, compositionOffset: -40),
                ],
                data: Data(count: 20),
                isVideo: true,
            ),
        ])
        let trun = try #require(MP4Box.find("moof/traf/trun", in: segment))
        let bytes = [UInt8](trun.payload)
        #expect(bytes[0] == 1) // version
        #expect(Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]) == 0x000F01)

        // Second sample entry: duration, size, flags, then signed offset -40.
        let secondSample = trun.payload.dropFirst(12 + 16)
        let flags = secondSample.dropFirst(8).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(flags == 0x0101_0000)
        let offset = secondSample.dropFirst(12).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(Int32(bitPattern: UInt32(offset)) == -40)
    }
}

// MARK: - End-to-end remux

@Suite("MatroskaFMP4Remuxer")
struct MatroskaFMP4RemuxerTests {
    /// Fixture: HEVC video with a profile-7 Dolby Vision declaration plus
    /// E-AC-3 audio, two clusters, B-frame presentation order in the second.
    private func fixture() -> MatroskaFixtureBuilder {
        let dvcC = DolbyVisionConfiguration(
            profile: 7, level: 6, rpuPresent: true, elPresent: true, blPresent: true, blSignalCompatibilityID: 6,
        )
        var builder = MatroskaFixtureBuilder()
        builder.tracks = [
            MatroskaFixtureBuilder.Track(
                number: 1,
                type: 1,
                codecID: "V_MPEGH/ISO/HEVC",
                codecPrivate: CodecFixtures.hvcC,
                width: 3840,
                height: 2160,
                additionMappings: [("dvcC", dvcC.boxData())],
            ),
            MatroskaFixtureBuilder.Track(
                number: 2,
                type: 17,
                codecID: "S_HDMV/PGS",
            ),
            MatroskaFixtureBuilder.Track(
                number: 3,
                type: 2,
                codecID: "A_TRUEHD",
            ),
            MatroskaFixtureBuilder.Track(
                number: 4,
                type: 2,
                codecID: "A_EAC3",
                channels: 6,
                samplingFrequency: 48000,
            ),
        ]
        let irap = CodecFixtures.hevcAccessUnit([(type: 20, size: 300), (type: 63, size: 20), (type: 62, size: 30)])
        let slice = CodecFixtures.hevcAccessUnit([(type: 1, size: 100), (type: 63, size: 10), (type: 62, size: 30)])
        builder.clusters = [
            MatroskaFixtureBuilder.Cluster(timestamp: 0, blocks: [
                .init(track: 1, relativeTime: 0, keyframe: true, framePayloads: [irap]),
                .init(track: 4, relativeTime: 0, keyframe: true, framePayloads: [
                    CodecFixtures.eac3Syncframe(), CodecFixtures.eac3Syncframe(),
                ], lacing: .fixed),
                .init(track: 1, relativeTime: 40, keyframe: false, framePayloads: [slice]),
            ]),
            // Presentation order I(4000) P(4120) B(4040) B(4080): decode
            // order storage, so DTS must be synthesized.
            MatroskaFixtureBuilder.Cluster(timestamp: 4000, blocks: [
                .init(track: 1, relativeTime: 0, keyframe: true, framePayloads: [irap]),
                .init(track: 1, relativeTime: 120, keyframe: false, framePayloads: [slice]),
                .init(track: 1, relativeTime: 40, keyframe: false, framePayloads: [slice]),
                .init(track: 1, relativeTime: 80, keyframe: false, framePayloads: [slice]),
            ]),
        ]
        return builder
    }

    private func makeRemuxer() async throws -> (MatroskaDemuxer, MatroskaFMP4Remuxer, MatroskaIndex) {
        let demuxer = MatroskaDemuxer(source: DataByteSource(fixture().build()))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)
        return (demuxer, remuxer, index)
    }

    @Test("Track selection skips subtitles and unsupported audio")
    func trackSelection() async throws {
        let (_, remuxer, _) = try await makeRemuxer()
        #expect(remuxer.tracks.video.number == 1)
        #expect(remuxer.tracks.audio?.number == 4)
        #expect(remuxer.tracks.audio?.codecID == "A_EAC3")
    }

    /// The init segment for a profile-7 source must carry NO Dolby Vision
    /// box. It previously declared 8.1, which is what produced chroma
    /// corruption on every profile-7 source on the SDR-panel rig
    /// (2026-08-11): the relabelled box left a dual-layer RPU in a stream
    /// that no longer has its enhancement layer. Unsignalled means the
    /// decoder renders the HDR10 base layer, which is correct.
    @Test("Init segment carries no DV box for a profile-7 source")
    func initSegmentDolbyVision() async throws {
        let (demuxer, remuxer, index) = try await makeRemuxer()
        let first = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.segmentDataEnd)
        let segment = try remuxer.makeInitializationSegment(firstCluster: first)

        let stsd = try #require(MP4Box.find("moov/trak/mdia/minf/stbl/stsd", in: segment))
        let hvc1 = try #require(MP4Box.parse(stsd.payload.dropFirst(8)).first)
        let children = MP4Box.parse(hvc1.payload.dropFirst(78))
        #expect(children.map(\.type) == ["hvcC"])
    }

    @Test("Profile-7 samples lose their enhancement-layer NALUs in the mux")
    func enhancementLayerFiltered() async throws {
        let (demuxer, remuxer, index) = try await makeRemuxer()
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.cues[1].clusterOffset)
        let fragment = try remuxer.makeFragment(sequence: 1, cluster: cluster, nextSpanHead: nil)

        let trun = try #require(MP4Box.find("moof/traf/trun", in: fragment))
        // Sample 1: IRAP(300) + RPU(30) with 4-byte prefixes and 2-byte NAL
        // headers; the 20-byte EL and its prefix are gone.
        let sampleSize = trun.payload.dropFirst(12).dropFirst(4).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(sampleSize == (4 + 2 + 300) + (4 + 2 + 30))
    }

    @Test("Decode times are synthesized from sorted presentation times")
    func decodeTimeSynthesis() async throws {
        let (demuxer, remuxer, index) = try await makeRemuxer()
        let cluster = try await demuxer.readClusters(from: index.cues[1].clusterOffset, to: index.segmentDataEnd)
        let fragment = try remuxer.makeFragment(sequence: 2, cluster: cluster, nextSpanHead: nil)

        let tfdt = try #require(MP4Box.find("moof/traf/tfdt", in: fragment))
        let baseTime = tfdt.payload.dropFirst(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(baseTime == 4000)

        let trun = try #require(MP4Box.find("moof/traf/trun", in: fragment))
        var samples: [(duration: Int, offset: Int32)] = []
        var cursor = trun.payload.dropFirst(12)
        for _ in 0 ..< 4 {
            let duration = cursor.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let offset = cursor.dropFirst(12).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            samples.append((duration, Int32(bitPattern: UInt32(offset))))
            cursor = cursor.dropFirst(16)
        }
        // PTS storage order 4000,4120,4040,4080 -> DTS 4000,4040,4080,4120.
        #expect(samples.map(\.duration) == [40, 40, 40, 40])
        #expect(samples.map(\.offset) == [0, 80, -40, -40])
    }

    /// The #99 regression: a GOP that straddles the span boundary stores its
    /// final frames in the NEXT span's opening cluster, before that span's
    /// cued keyframe. Fragments must re-partition at keyframes — the earlier
    /// span claims those tail frames, the later span drops them — and the
    /// last sample keeps its honest one-frame duration instead of stretching
    /// to the next cue. Together the two fragments' decode timelines tile
    /// exactly; without the re-partition, `tfdt` stepped backwards one
    /// reorder-depth at segment boundaries, which played as the periodic
    /// skip with zero dropped frames.
    @Test("Straddling GOP tails re-partition at keyframes and the timelines tile")
    func straddlingGOPRepartition() async throws {
        var builder = fixture()
        // The previous GOP's tail Bs (3920, 3960) are stored at the head of
        // the second cluster, before its cued keyframe at 4000.
        builder.clusters[1] = MatroskaFixtureBuilder.Cluster(timestamp: 4000, blocks: [
            .init(track: 1, relativeTime: -80, keyframe: false, framePayloads: [
                CodecFixtures.hevcAccessUnit([(type: 1, size: 100), (type: 63, size: 10), (type: 62, size: 30)]),
            ]),
            .init(track: 1, relativeTime: -40, keyframe: false, framePayloads: [
                CodecFixtures.hevcAccessUnit([(type: 1, size: 100), (type: 63, size: 10), (type: 62, size: 30)]),
            ]),
            .init(track: 1, relativeTime: 0, keyframe: true, framePayloads: [
                CodecFixtures.hevcAccessUnit([(type: 20, size: 300), (type: 63, size: 20), (type: 62, size: 30)]),
            ]),
            .init(track: 1, relativeTime: 40, keyframe: false, framePayloads: [
                CodecFixtures.hevcAccessUnit([(type: 1, size: 100), (type: 63, size: 10), (type: 62, size: 30)]),
            ]),
        ])
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)

        func timing(of fragment: Data, sampleCount: Int) throws -> (base: Int, durations: [Int]) {
            let tfdt = try #require(MP4Box.find("moof/traf/tfdt", in: fragment))
            let base = tfdt.payload.dropFirst(4).reduce(0) { ($0 << 8) | Int($1) }
            let trun = try #require(MP4Box.find("moof/traf/trun", in: fragment))
            var durations: [Int] = []
            var cursor = trun.payload.dropFirst(12)
            for _ in 0 ..< sampleCount {
                durations.append(cursor.prefix(4).reduce(0) { ($0 << 8) | Int($1) })
                cursor = cursor.dropFirst(16)
            }
            return (base, durations)
        }

        // Fragment 1 claims the tail Bs from the second cluster's head.
        let span1 = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.cues[1].clusterOffset)
        let head2 = try await demuxer.readFirstCluster(at: index.cues[1].clusterOffset, endBound: index.segmentDataEnd)
        let fragment1 = try remuxer.makeFragment(sequence: 1, cluster: span1, nextSpanHead: head2)
        // Own frames present at 0 and 40, claimed tails at 3920 and 3960;
        // the last sample is one honest frame (40), NOT stretched to 4000.
        let timing1 = try timing(of: fragment1, sampleCount: 4)
        #expect(timing1.base == 0)
        #expect(timing1.durations == [40, 3880, 40, 40])

        // Fragment 2 drops its pre-keyframe head and starts at the keyframe.
        let span2 = try await demuxer.readClusters(from: index.cues[1].clusterOffset, to: index.segmentDataEnd)
        let fragment2 = try remuxer.makeFragment(sequence: 2, cluster: span2, nextSpanHead: nil)
        let timing2 = try timing(of: fragment2, sampleCount: 2)
        #expect(timing2.base == 4000)
        #expect(timing2.durations == [40, 40])

        // The tiling invariant #99 hangs on: one continuous decode clock.
        #expect(timing1.base + timing1.durations.reduce(0, +) == timing2.base)
    }

    @Test("Laced audio spreads durations to the next distinct timestamp")
    func audioLaceDurations() async throws {
        var builder = fixture()
        // Two laced E-AC-3 frames at t=0, then one at t=64: 32 ticks each.
        builder.clusters[0].blocks.append(
            .init(track: 4, relativeTime: 64, keyframe: true, framePayloads: [CodecFixtures.eac3Syncframe()]),
        )
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)

        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.cues[1].clusterOffset)
        let fragment = try remuxer.makeFragment(sequence: 1, cluster: cluster, nextSpanHead: nil)

        let trafs = MP4Box.findAll("moof/traf", in: fragment)
        let audioTraf = try #require(trafs.first { traf in
            let tfhd = traf.children.first { $0.type == "tfhd" }
            let trackID = tfhd?.payload.dropFirst(4).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            return trackID == 4
        })
        let trun = try #require(audioTraf.children.first { $0.type == "trun" })
        var durations: [Int] = []
        var cursor = trun.payload.dropFirst(12)
        for _ in 0 ..< 3 {
            durations.append(cursor.prefix(4).reduce(0) { ($0 << 8) | Int($1) })
            cursor = cursor.dropFirst(8)
        }
        #expect(durations.prefix(2) == [32, 32])
    }

    @Test("A source with only unsupported video is refused")
    func unsupportedVideoRefused() async throws {
        var builder = fixture()
        builder.tracks[0].codecID = "V_VC1"
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        #expect(MatroskaFMP4Remuxer.selectTracks(from: index) == nil)
    }

    @Test("End to end on the real ffmpeg fixture: init plus every fragment")
    func ffmpegFixtureRemux() async throws {
        let url = try #require(Bundle.module.url(forResource: "hevc-ac3", withExtension: "mkv", subdirectory: "Fixtures"))
        let demuxer = try MatroskaDemuxer(source: DataByteSource(Data(contentsOf: url)))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)

        let firstCluster = try await demuxer.readClusters(
            from: index.cues[0].clusterOffset,
            to: index.cues.count > 1 ? index.cues[1].clusterOffset : index.segmentDataEnd,
        )
        let initSegment = try remuxer.makeInitializationSegment(firstCluster: firstCluster)
        #expect(MP4Box.parse(initSegment).map(\.type) == ["ftyp", "moov"])
        #expect(MP4Box.findAll("moov/trak", in: initSegment).count == 2)

        for (i, cue) in index.cues.enumerated() {
            let endBound = i + 1 < index.cues.count ? index.cues[i + 1].clusterOffset : index.segmentDataEnd
            let cluster = try await demuxer.readClusters(from: cue.clusterOffset, to: endBound)
            let fragment = try remuxer.makeFragment(sequence: i + 1, cluster: cluster, nextSpanHead: nil)
            #expect(MP4Box.parse(fragment).map(\.type) == ["moof", "mdat"])
        }
    }
}

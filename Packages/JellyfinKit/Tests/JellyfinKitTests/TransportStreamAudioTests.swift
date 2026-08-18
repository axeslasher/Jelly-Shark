import Foundation
@testable import JellyfinKit
import Testing

// MARK: - TS fixture

/// Builds a minimal single-program MPEG-TS carrying ADTS AAC, the shape
/// Jellyfin's audio-only HLS transcode serves (#249).
private enum TSFixture {
    static let audioPID = 0x101
    static let pmtPID = 0x1000

    /// Short payloads are stuffed through the adaptation field, the way real
    /// muxers do it — trailing payload padding would corrupt PES reassembly.
    static func packet(pid: Int, payloadUnitStart: Bool, counter: UInt8, payload: Data) -> Data {
        let body = payload.prefix(184)
        var packet = Data([
            0x47,
            UInt8((payloadUnitStart ? 0x40 : 0x00) | (pid >> 8) & 0x1F),
            UInt8(pid & 0xFF),
            UInt8((body.count < 184 ? 0x30 : 0x10) | (counter & 0x0F)),
        ])
        if body.count < 184 {
            let adaptationLength = 183 - body.count
            packet += Data([UInt8(adaptationLength)])
            if adaptationLength > 0 {
                packet += Data([0x00]) + Data(repeating: 0xFF, count: adaptationLength - 1)
            }
        }
        packet += body
        return packet
    }

    static func pat() -> Data {
        // pointer, table 0, section for program 1 -> pmtPID. CRC unchecked.
        var section = Data([0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00])
        section += Data([0x00, 0x01, UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)])
        section += Data(count: 4) // CRC placeholder
        return packet(pid: 0, payloadUnitStart: true, counter: 0, payload: section)
    }

    static func pmt() -> Data {
        var section = Data([0x00, 0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00])
        section += Data([UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF)]) // PCR PID
        section += Data([0xF0, 0x00]) // program_info_length 0
        section += Data([0x0F, UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF), 0xF0, 0x00]) // ADTS AAC stream
        section += Data(count: 4) // CRC placeholder
        return packet(pid: pmtPID, payloadUnitStart: true, counter: 0, payload: section)
    }

    /// One ADTS frame: 48 kHz (index 3), 6-channel, AAC-LC (profile 1).
    static func adtsFrame(bodyByte: UInt8, bodySize: Int = 5) -> Data {
        let frameLength = 7 + bodySize
        var frame = Data([
            0xFF, 0xF1, // sync, MPEG-4, no CRC
            UInt8(1 << 6 | 3 << 2 | (6 >> 2)), // profile 1 (LC), sfi 3, chanCfg high bit
            UInt8((6 & 0x3) << 6 | UInt8(frameLength >> 11)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8((frameLength & 0x7) << 5 | 0x1F),
            0xFC,
        ])
        frame += Data(repeating: bodyByte, count: bodySize)
        return frame
    }

    static func pes(pts: Int64, frames: [Data]) -> Data {
        let body = frames.reduce(Data(), +)
        var pes = Data([0x00, 0x00, 0x01, 0xC0])
        let length = 3 + 5 + body.count
        pes += Data([UInt8(length >> 8), UInt8(length & 0xFF)])
        pes += Data([0x80, 0x80, 0x05]) // flags: PTS only, header length 5
        pes += Data([
            UInt8(0x21 | ((pts >> 30) & 0x7) << 1),
            UInt8((pts >> 22) & 0xFF),
            UInt8(0x01 | ((pts >> 15) & 0x7F) << 1),
            UInt8((pts >> 7) & 0xFF),
            UInt8(0x01 | (pts & 0x7F) << 1),
        ])
        return pes + body
    }

    /// A whole segment: PAT, PMT, then the PES packets split across TS
    /// packets (a frame straddling TS packets is the normal case).
    static func segment(pesPackets: [Data]) -> Data {
        var ts = pat() + pmt()
        var counter: UInt8 = 0
        for pes in pesPackets {
            var offset = pes.startIndex
            var first = true
            while offset < pes.endIndex {
                let chunk = pes[offset ..< min(offset + 184, pes.endIndex)]
                ts += packet(pid: audioPID, payloadUnitStart: first, counter: counter, payload: Data(chunk))
                counter = counter &+ 1
                first = false
                offset = chunk.endIndex
            }
        }
        return ts
    }
}

// MARK: - Extraction

@Suite("TransportStreamAudioExtractor")
struct TransportStreamAudioExtractorTests {
    @Test("Extracts stripped AAC frames with per-frame PES-derived timestamps")
    func extraction() throws {
        // Two PES packets: 3 frames from pts 900000, 2 from the tiled
        // continuation — 1920 ticks per 1024-sample frame at 48 kHz.
        let ts = TSFixture.segment(pesPackets: [
            TSFixture.pes(pts: 900_000, frames: [
                TSFixture.adtsFrame(bodyByte: 0xA0), TSFixture.adtsFrame(bodyByte: 0xA1), TSFixture.adtsFrame(bodyByte: 0xA2),
            ]),
            TSFixture.pes(pts: 905_760, frames: [
                TSFixture.adtsFrame(bodyByte: 0xA3), TSFixture.adtsFrame(bodyByte: 0xA4),
            ]),
        ])
        let (info, frames) = try TransportStreamAudioExtractor.extract(from: ts)

        #expect(info.sampleRate == 48000)
        #expect(info.channelCount == 6)
        #expect(info.samplesPerFrame == 1024)
        // AudioSpecificConfig: AAC-LC (object type 2), sfi 3, 6 channels.
        #expect(info.audioSpecificConfig == Data([0x11, 0xB0]))

        #expect(frames.count == 5)
        #expect(frames.map(\.pts90k) == [900_000, 901_920, 903_840, 905_760, 907_680])
        // Headers stripped, payloads intact.
        #expect(frames[0].data == Data(repeating: 0xA0, count: 5))
        #expect(frames[4].data == Data(repeating: 0xA4, count: 5))
    }

    @Test("Refuses non-TS bytes and streams with no AAC elementary stream")
    func refusals() {
        #expect(throws: TransportStreamAudioError.self) {
            _ = try TransportStreamAudioExtractor.extract(from: Data(repeating: 0xFF, count: 188))
        }
        #expect(throws: TransportStreamAudioError.self) {
            // Valid packets, but nothing but a PAT.
            _ = try TransportStreamAudioExtractor.extract(from: TSFixture.pat())
        }
    }
}

// MARK: - Run alignment

@Suite("TranscodedAudioRun")
struct TranscodedAudioRunTests {
    @Test("Seek runs drop exactly the frames declared below the seek point")
    func seekRunPriming() {
        // Measured shape: -ss 300 emits priming at 299.9573s and 299.9787s,
        // content exactly at 300 — two whole frames below the target.
        let runStart: Int64 = 300 * 90000
        #expect(TranscodedAudioRun.primingFrameCount(
            firstPTS90k: runStart + TranscodedAudioRun.muxOffset90k - 3840,
            runStartTicks90k: runStart,
            ticksPerFrame90k: 1920,
        ) == 2)
        // First frame exactly on the seek point: nothing to drop.
        #expect(TranscodedAudioRun.primingFrameCount(
            firstPTS90k: runStart + TranscodedAudioRun.muxOffset90k,
            runStartTicks90k: runStart,
            ticksPerFrame90k: 1920,
        ) == 0)
        // A partial frame below the point still gets dropped whole.
        #expect(TranscodedAudioRun.primingFrameCount(
            firstPTS90k: runStart + TranscodedAudioRun.muxOffset90k - 1000,
            runStartTicks90k: runStart,
            ticksPerFrame90k: 1920,
        ) == 1)
    }

    @Test("The grid anchors at the boundary until the declared time disagrees past half a frame")
    func anchorSnap() {
        let runStart: Int64 = 300 * 90000 // segment boundary at 300 s
        let onTime = runStart + TranscodedAudioRun.muxOffset90k
        // Exact landing and sub-half-frame jitter keep the boundary anchor.
        #expect(TranscodedAudioRun.anchorTicks(
            firstKeptPTS90k: onTime, runStartTicks90k: runStart, ticksPerFrame90k: 1920, sampleRate: 48000,
        ) == 300 * 48000)
        #expect(TranscodedAudioRun.anchorTicks(
            firstKeptPTS90k: onTime + 900, runStartTicks90k: runStart, ticksPerFrame90k: 1920, sampleRate: 48000,
        ) == 300 * 48000)
        // Past half a frame the declared time wins — the device-measured
        // shape: -ss landed 1845 ticks (20.5 ms) late on the source audio.
        #expect(TranscodedAudioRun.anchorTicks(
            firstKeptPTS90k: onTime + 1845, runStartTicks90k: runStart, ticksPerFrame90k: 1920, sampleRate: 48000,
        ) == 300 * 48000 + 984) // 1845 * 48000 / 90000, rounded
        // No trustworthy declared clock (the from-zero clamp): boundary.
        #expect(TranscodedAudioRun.anchorTicks(
            firstKeptPTS90k: nil, runStartTicks90k: 0, ticksPerFrame90k: 1920, sampleRate: 48000,
        ) == 0)
        // Non-48k rates convert the boundary exactly (3 s segments).
        #expect(TranscodedAudioRun.anchorTicks(
            firstKeptPTS90k: nil, runStartTicks90k: 270_000, ticksPerFrame90k: 2090, sampleRate: 44100,
        ) == 132_300)
    }

    @Test("The from-zero run's clamped timeline gets the constant drop")
    func fromZeroPriming() {
        // Measured shape: the mpegts mux clamps the run's first PTS to the
        // offset exactly, hiding the priming from the timestamps.
        #expect(TranscodedAudioRun.primingFrameCount(
            firstPTS90k: TranscodedAudioRun.muxOffset90k,
            runStartTicks90k: 0,
            ticksPerFrame90k: 1920,
        ) == TranscodedAudioRun.assumedFromZeroPrimingFrames)
        // A server that declares from-zero priming honestly takes the
        // declared path instead.
        #expect(TranscodedAudioRun.primingFrameCount(
            firstPTS90k: TranscodedAudioRun.muxOffset90k - 3840,
            runStartTicks90k: 0,
            ticksPerFrame90k: 1920,
        ) == 2)
    }
}

// MARK: - External-audio muxing

@Suite("External audio muxing")
struct ExternalAudioMuxingTests {
    @Test("Audio track can run on its own sample-rate timescale")
    func audioTimescale() throws {
        let audio = FMP4Muxer.AudioTrack(
            trackID: 5,
            configuration: .aac(audioSpecificConfig: Data([0x11, 0xB0])),
            channelCount: 6,
            sampleRate: 48000,
        )
        let initSegment = FMP4Muxer.initializationSegment(
            video: nil, audio: audio, timescale: 1000, audioTimescale: 48000,
        )
        // The muxer writes version-1 headers: version/flags (4) then 64-bit
        // creation and modification times (16) put the timescale at payload
        // offset 20.
        let mdhd = try #require(MP4Box.find("moov/trak/mdia/mdhd", in: initSegment))
        let timescale = mdhd.payload[20 ..< 24].reduce(0) { ($0 << 8) | Int($1) }
        #expect(timescale == 48000)
        // The movie clock keeps the shared timescale.
        let mvhd = try #require(MP4Box.find("moov/mvhd", in: initSegment))
        let movieTimescale = mvhd.payload[20 ..< 24].reduce(0) { ($0 << 8) | Int($1) }
        #expect(movieTimescale == 1000)
    }

    @Test("A remuxer without carriable audio muxes an external fragment")
    func externalFragment() async throws {
        // DTS-default source: video is carriable, audio is not.
        var builder = MatroskaFixtureBuilder()
        builder.tracks = [
            MatroskaFixtureBuilder.Track(
                number: 1, type: 1, codecID: "V_MPEGH/ISO/HEVC",
                codecPrivate: CodecFixtures.hvcC, width: 3840, height: 2160,
            ),
            MatroskaFixtureBuilder.Track(number: 2, type: 2, codecID: "A_DTS", channels: 6, samplingFrequency: 48000),
        ]
        let irap = CodecFixtures.hevcAccessUnit([(type: 20, size: 300)])
        builder.clusters = [
            MatroskaFixtureBuilder.Cluster(timestamp: 0, blocks: [
                .init(track: 1, relativeTime: 0, keyframe: true, framePayloads: [irap]),
            ]),
        ]
        let demuxer = MatroskaDemuxer(source: DataByteSource(builder.build()))
        let index = try await demuxer.loadIndex()
        let tracks = try #require(MatroskaFMP4Remuxer.selectTracks(from: index))
        #expect(tracks.audio == nil)
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks.droppingAudio())

        let audioTrack = FMP4Muxer.AudioTrack(
            trackID: 3,
            configuration: .aac(audioSpecificConfig: Data([0x11, 0xB0])),
            channelCount: 6,
            sampleRate: 48000,
        )
        let initSegment = try remuxer.makeExternalAudioInitializationSegment(audio: audioTrack, audioTimescale: 48000)
        let handlers = MP4Box.findAll("moov/trak", in: initSegment).compactMap {
            MP4Box.find("mdia/hdlr", in: $0.payload).map { String(decoding: $0.payload[8 ..< 12], as: UTF8.self) }
        }
        #expect(handlers == ["vide", "soun"])

        // The external fragment rides the media segment alongside the video.
        let cluster = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: index.segmentDataEnd)
        let audioFragment = FMP4Muxer.TrackFragment(
            trackID: 3,
            baseDecodeTime: 0,
            samples: [FMP4Muxer.Sample(duration: 1024, size: 4, isSync: true)],
            data: Data([1, 2, 3, 4]),
            isVideo: false,
        )
        let segment = try remuxer.makeFragment(
            sequence: 1, cluster: cluster, nextSpanHead: nil, externalAudioFragment: audioFragment,
        )
        let trafs = MP4Box.findAll("moof/traf", in: segment)
        #expect(trafs.count == 2)
        let trackIDs = trafs.compactMap {
            MP4Box.find("tfhd", in: $0.payload).map { $0.payload[4 ..< 8].reduce(0) { ($0 << 8) | Int($1) } }
        }
        #expect(trackIDs == [1, 3])
        // The shared mdat carries the audio payload after the video sample.
        let mdat = try #require(MP4Box.find("mdat", in: segment))
        #expect(mdat.payload.suffix(4) == Data([1, 2, 3, 4]))
    }
}

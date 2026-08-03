import Foundation

// Fragmented-MP4 writer for the MKV remux (#176). Pure `Data` assembly, host
// testable, same idiom as `TrickplayIFrameMuxer` — which stays untouched
// because it is merged, single-purpose code; the ~40 lines of box primitives
// are duplicated here deliberately.
//
// The initialization segment carries real track headers (hvcC/avcC copied
// from Matroska CodecPrivate, dvcC/dvvC from BlockAdditionMapping, audio
// configuration from `AudioSampleEntryConfiguration`) plus `mvex`, so the
// file is valid with any number of `moof`/`mdat` pairs appended — which is
// what makes #172's progressive mode possible without a full sample index.

public enum FMP4Muxer {
    public enum VideoCodec: Sendable, Equatable {
        /// `hvc1` with the hvcC record, optionally Dolby Vision signalled.
        case hevc(hvcC: Data, dolbyVision: DolbyVisionConfiguration?)
        /// `avc1` with the avcC record.
        case h264(avcC: Data)
    }

    public struct VideoTrack: Sendable, Equatable {
        public let trackID: Int
        public let codec: VideoCodec
        public let width: Int
        public let height: Int

        public init(trackID: Int, codec: VideoCodec, width: Int, height: Int) {
            self.trackID = trackID
            self.codec = codec
            self.width = width
            self.height = height
        }
    }

    public struct AudioTrack: Sendable, Equatable {
        public let trackID: Int
        public let configuration: AudioSampleEntryConfiguration
        public let channelCount: Int
        public let sampleRate: Int

        public init(trackID: Int, configuration: AudioSampleEntryConfiguration, channelCount: Int, sampleRate: Int) {
            self.trackID = trackID
            self.configuration = configuration
            self.channelCount = channelCount
            self.sampleRate = sampleRate
        }
    }

    public struct Sample: Sendable, Equatable {
        public let duration: Int
        public let size: Int
        public let isSync: Bool
        /// Presentation minus decode time; may be negative (signalled via
        /// version-1 `trun`).
        public let compositionOffset: Int

        public init(duration: Int, size: Int, isSync: Bool, compositionOffset: Int = 0) {
            self.duration = duration
            self.size = size
            self.isSync = isSync
            self.compositionOffset = compositionOffset
        }
    }

    /// One track's contribution to a media segment.
    public struct TrackFragment: Sendable {
        public let trackID: Int
        public let baseDecodeTime: Int64
        public let samples: [Sample]
        /// Sample payloads concatenated in `samples` order.
        public let data: Data
        public let isVideo: Bool

        public init(trackID: Int, baseDecodeTime: Int64, samples: [Sample], data: Data, isVideo: Bool) {
            self.trackID = trackID
            self.baseDecodeTime = baseDecodeTime
            self.samples = samples
            self.data = data
            self.isVideo = isVideo
        }
    }

    // MARK: - Initialization segment

    /// `ftyp` + `moov` for the given tracks. `timescale` is ticks per second
    /// (from the Matroska timestamp scale, typically 1000).
    public static func initializationSegment(
        video: VideoTrack?,
        audio: AudioTrack?,
        timescale: Int,
    ) -> Data {
        // The moov declares NO duration anywhere — not mvhd/tkhd/mdhd (a
        // moov-level duration is read as pre-fragment content and the
        // fragments extend it, doubling the reported runtime; measured on
        // the macOS host during #176) and not mehd either: with a duration
        // already answered, AVFoundation never engages the sidx and scans
        // every moof over HTTP before readiness (2026-08-02 device round).
        // The ffmpeg head it demonstrably trusts carries duration only in
        // the sidx; mirror that.
        var traks = Data()
        var trexes = Data()
        var maxTrackID = 0
        if let video {
            traks += videoTrak(video, timescale: timescale, durationTicks: 0)
            trexes += trex(trackID: video.trackID)
            maxTrackID = max(maxTrackID, video.trackID)
        }
        if let audio {
            traks += audioTrak(audio, timescale: timescale, durationTicks: 0)
            trexes += trex(trackID: audio.trackID)
            maxTrackID = max(maxTrackID, audio.trackID)
        }
        let mvex = box("mvex", trexes)
        let moov = box("moov", mvhd(timescale: timescale, durationTicks: 0, nextTrackID: maxTrackID + 1) + traks + mvex)
        return ftyp() + moov
    }

    // MARK: - Media segment

    /// One `moof` + `mdat` pair carrying the given track fragments. Each
    /// `traf`'s data-offset points at its region of the shared `mdat`.
    public static func mediaSegment(sequence: Int, fragments: [TrackFragment]) -> Data {
        let mfhd = fullBox("mfhd", version: 0, flags: 0, payload: uint32(sequence))

        // Build every traf with a zero data-offset first, then patch offsets
        // once the moof size is known.
        var trafs: [Data] = []
        var offsetPositions: [Int] = [] // position of trun data_offset within each traf
        for fragment in fragments {
            let (traf, offsetPosition) = trackFragmentBox(fragment)
            trafs.append(traf)
            offsetPositions.append(offsetPosition)
        }

        var moof = box("moof", mfhd + trafs.reduce(Data(), +))
        let mdatPayloadStart = moof.count + 8

        // Patch each traf's trun data_offset: moof header (8) + mfhd + the
        // trafs before it, plus its own offset position.
        var runningTrafStart = 8 + mfhd.count
        var runningDataOffset = mdatPayloadStart
        for (index, traf) in trafs.enumerated() {
            let position = runningTrafStart + offsetPositions[index]
            moof.replaceSubrange(position ..< position + 4, with: int32(runningDataOffset))
            runningTrafStart += traf.count
            runningDataOffset += fragments[index].data.count
        }

        let mdatPayload = fragments.reduce(Data()) { $0 + $1.data }
        return moof + box("mdat", mdatPayload)
    }

    private static func trackFragmentBox(_ fragment: TrackFragment) -> (traf: Data, dataOffsetPosition: Int) {
        // default-base-is-moof | default-sample-flags-present
        let defaultFlags: UInt32 = fragment.isVideo ? 0x0101_0000 : 0x0200_0000
        let tfhd = fullBox("tfhd", version: 0, flags: 0x020020, payload: uint32(fragment.trackID) + uint32(Int(defaultFlags)))
        let tfdt = fullBox("tfdt", version: 1, flags: 0, payload: uint64(Int(fragment.baseDecodeTime)))

        // data-offset + per-sample duration/size, plus per-sample flags and
        // signed composition offsets for video (version 1 trun).
        let flags = fragment.isVideo ? 0x000F01 : 0x000301
        var trunPayload = uint32(fragment.samples.count) + int32(0)
        for sample in fragment.samples {
            trunPayload += uint32(sample.duration)
            trunPayload += uint32(sample.size)
            if fragment.isVideo {
                trunPayload += uint32(Int(sample.isSync ? 0x0200_0000 : 0x0101_0000))
                trunPayload += int32(sample.compositionOffset)
            }
        }
        let trun = fullBox("trun", version: fragment.isVideo ? 1 : 0, flags: flags, payload: trunPayload)

        let traf = box("traf", tfhd + tfdt + trun)
        // traf hdr (8) + tfhd + tfdt + trun hdr (8) + fullbox hdr (4) +
        // sample count (4) = position of data_offset
        let dataOffsetPosition = 8 + tfhd.count + tfdt.count + 8 + 4 + 4
        return (traf, dataOffsetPosition)
    }

    // MARK: - Track boxes

    private static func ftyp() -> Data {
        // The exact brand set of the ffmpeg head AVFoundation trusts.
        box("ftyp", fourCC("isom") + uint32(512) + fourCC("isom") + fourCC("iso6") + fourCC("dby1") + fourCC("iso2") + fourCC("mp41"))
    }

    private static func videoTrak(_ track: VideoTrack, timescale: Int, durationTicks: Int) -> Data {
        let sampleEntry: Data = switch track.codec {
        case let .hevc(hvcC, dolbyVision):
            visualSampleEntry(
                type: "hvc1",
                width: track.width,
                height: track.height,
                configurations: box("hvcC", hvcC) + (dolbyVision?.boxData() ?? Data()),
            )
        case let .h264(avcC):
            visualSampleEntry(type: "avc1", width: track.width, height: track.height, configurations: box("avcC", avcC))
        }
        let stsd = fullBox("stsd", version: 0, flags: 0, payload: uint32(1) + sampleEntry)
        let minf = box(
            "minf",
            fullBox("vmhd", version: 0, flags: 1, payload: Data(count: 8))
                + box("dinf", dref())
                + emptyStbl(stsd),
        )
        let mdia = box(
            "mdia",
            mdhd(timescale: timescale, durationTicks: durationTicks)
                + hdlr(type: "vide", name: "VideoHandler")
                + minf,
        )
        return box("trak", tkhd(trackID: track.trackID, width: track.width, height: track.height, durationTicks: durationTicks, isAudio: false) + mdia)
    }

    private static func audioTrak(_ track: AudioTrack, timescale: Int, durationTicks: Int) -> Data {
        var entry = Data(count: 6) // reserved
        entry += uint16(1) // data_reference_index
        entry += Data(count: 8) // reserved
        entry += uint16(track.channelCount) + uint16(16) // channelcount, samplesize
        entry += Data(count: 4) // pre_defined, reserved
        entry += uint32(track.sampleRate << 16) // 16.16 fixed
        entry += track.configuration.configurationBox
        let sampleEntry = box(track.configuration.entryType, entry)
        let stsd = fullBox("stsd", version: 0, flags: 0, payload: uint32(1) + sampleEntry)
        let minf = box(
            "minf",
            fullBox("smhd", version: 0, flags: 0, payload: Data(count: 4))
                + box("dinf", dref())
                + emptyStbl(stsd),
        )
        let mdia = box(
            "mdia",
            mdhd(timescale: timescale, durationTicks: durationTicks)
                + hdlr(type: "soun", name: "SoundHandler")
                + minf,
        )
        return box("trak", tkhd(trackID: track.trackID, width: 0, height: 0, durationTicks: durationTicks, isAudio: true) + mdia)
    }

    private static func visualSampleEntry(type: String, width: Int, height: Int, configurations: Data) -> Data {
        var entry = Data(count: 6) // reserved
        entry += uint16(1) // data_reference_index
        entry += Data(count: 16) // pre_defined / reserved
        entry += uint16(width) + uint16(height)
        entry += uint32(0x0048_0000) + uint32(0x0048_0000) // 72 dpi
        entry += uint32(0) // reserved
        entry += uint16(1) // frame_count
        entry += Data(count: 32) // compressorname
        entry += uint16(24) + Data([0xFF, 0xFF]) // depth, pre_defined -1
        entry += configurations
        return box(type, entry)
    }

    private static func emptyStbl(_ stsd: Data) -> Data {
        let empty = uint32(0)
        return box(
            "stbl",
            stsd
                + fullBox("stts", version: 0, flags: 0, payload: empty)
                + fullBox("stsc", version: 0, flags: 0, payload: empty)
                + fullBox("stsz", version: 0, flags: 0, payload: uint32(0) + uint32(0))
                + fullBox("stco", version: 0, flags: 0, payload: empty),
        )
    }

    private static func mvhd(timescale: Int, durationTicks: Int, nextTrackID: Int) -> Data {
        var payload = uint64(0) + uint64(0) // creation, modification (v1)
        payload += uint32(timescale) + uint64(durationTicks)
        payload += int32(0x0001_0000) // rate 1.0
        payload += Data([0x01, 0x00]) // volume 1.0
        payload += Data(count: 10) // reserved
        payload += identityMatrix()
        payload += Data(count: 24) // pre_defined
        payload += uint32(nextTrackID)
        return fullBox("mvhd", version: 1, flags: 0, payload: payload)
    }

    private static func tkhd(trackID: Int, width: Int, height: Int, durationTicks: Int, isAudio: Bool) -> Data {
        var payload = uint64(0) + uint64(0) // creation, modification (v1)
        payload += uint32(trackID)
        payload += uint32(0) // reserved
        payload += uint64(durationTicks)
        payload += Data(count: 8) // reserved
        payload += uint16(0) + uint16(0) // layer, alternate_group
        payload += isAudio ? Data([0x01, 0x00]) : Data([0x00, 0x00]) // volume
        payload += Data(count: 2) // reserved
        payload += identityMatrix()
        payload += uint32(width << 16) + uint32(height << 16)
        // enabled | in movie | in preview
        return fullBox("tkhd", version: 1, flags: 7, payload: payload)
    }

    private static func mdhd(timescale: Int, durationTicks: Int) -> Data {
        var payload = uint64(0) + uint64(0)
        payload += uint32(timescale) + uint64(durationTicks)
        payload += Data([0x55, 0xC4, 0x00, 0x00]) // language 'und'
        return fullBox("mdhd", version: 1, flags: 0, payload: payload)
    }

    private static func hdlr(type: String, name: String) -> Data {
        let payload = uint32(0) + fourCC(type) + Data(count: 12) + Data("\(name)\0".utf8)
        return fullBox("hdlr", version: 0, flags: 0, payload: payload)
    }

    private static func dref() -> Data {
        fullBox("dref", version: 0, flags: 0, payload: uint32(1) + fullBox("url ", version: 0, flags: 1, payload: Data()))
    }

    private static func trex(trackID: Int) -> Data {
        fullBox("trex", version: 0, flags: 0, payload: uint32(trackID) + uint32(1) + uint32(0) + uint32(0) + uint32(0))
    }

    // MARK: - Primitives

    private static func box(_ type: String, _ payload: Data) -> Data {
        uint32(8 + payload.count) + fourCC(type) + payload
    }

    private static func fullBox(_ type: String, version: UInt8, flags: Int, payload: Data) -> Data {
        var header = Data([version])
        header += Data([UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)])
        return box(type, header + payload)
    }

    private static func fourCC(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func uint16(_ value: Int) -> Data {
        let v = UInt16(clamping: value)
        return Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    private static func uint32(_ value: Int) -> Data {
        let v = UInt32(clamping: value)
        return Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func int32(_ value: Int) -> Data {
        let v = UInt32(bitPattern: Int32(clamping: value))
        return Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func uint64(_ value: Int) -> Data {
        let v = UInt64(value)
        return Data((0 ..< 8).reversed().map { UInt8((v >> ($0 * 8)) & 0xFF) })
    }

    private static func identityMatrix() -> Data {
        int32(0x0001_0000) + int32(0) + int32(0)
            + int32(0) + int32(0x0001_0000) + int32(0)
            + int32(0) + int32(0) + int32(0x4000_0000)
    }
}

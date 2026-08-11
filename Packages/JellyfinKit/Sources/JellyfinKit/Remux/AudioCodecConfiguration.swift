import Foundation

// Audio sample-entry configuration for the MKV remux (#176).
//
// HEVC hands us its configuration box readymade (CodecPrivate == hvcC), but
// audio is uneven: AAC and FLAC carry theirs in CodecPrivate, while AC-3 and
// E-AC-3 have no CodecPrivate at all — their `dac3`/`dec3` boxes must be
// synthesized by parsing the first syncframe of actual audio data, which is
// what ffmpeg's MP4 muxer does too.

/// The per-codec piece of an fMP4 audio sample entry: the entry's fourcc and
/// its codec-specific child box.
public struct AudioSampleEntryConfiguration: Sendable, Equatable {
    /// Sample entry type: "mp4a", "ac-3", "ec-3", or "fLaC".
    public let entryType: String
    /// The complete child box (esds / dac3 / dec3 / dfLa), header included.
    public let configurationBox: Data

    /// Build the configuration for a Matroska audio track. `firstFrame` is
    /// the payload of the track's first frame, required for AC-3/E-AC-3;
    /// returns `nil` for codecs the remux does not carry (TrueHD, DTS, …),
    /// which the caller must route back to the server path.
    public static func make(for track: MatroskaTrack, firstFrame: Data?) -> AudioSampleEntryConfiguration? {
        switch track.codecID {
        case "A_AAC":
            guard let asc = track.codecPrivate, !asc.isEmpty else { return nil }
            return AudioSampleEntryConfiguration(entryType: "mp4a", configurationBox: esds(audioSpecificConfig: asc))
        case "A_AC3":
            guard let frame = firstFrame, let dac3 = dac3(fromSyncframe: frame) else { return nil }
            return AudioSampleEntryConfiguration(entryType: "ac-3", configurationBox: dac3)
        case "A_EAC3":
            guard let frame = firstFrame, let dec3 = dec3(fromSample: frame) else { return nil }
            return AudioSampleEntryConfiguration(entryType: "ec-3", configurationBox: dec3)
        case "A_FLAC":
            guard let codecPrivate = track.codecPrivate, let dfLa = dfLa(fromCodecPrivate: codecPrivate) else { return nil }
            return AudioSampleEntryConfiguration(entryType: "fLaC", configurationBox: dfLa)
        default:
            return nil
        }
    }

    // MARK: - AAC

    /// Wrap the AudioSpecificConfig (Matroska CodecPrivate for A_AAC) in the
    /// MPEG-4 descriptor chain AVFoundation expects.
    static func esds(audioSpecificConfig asc: Data) -> Data {
        func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
            // Expandable length, single-byte form (all payloads here are tiny)
            Data([tag, UInt8(payload.count)]) + payload
        }
        let decoderSpecific = descriptor(0x05, asc)
        // objectTypeIndication 0x40 (MPEG-4 Audio), streamType 0x05 (audio)
        var decoderConfig = Data([0x40, 0x15])
        decoderConfig += Data(count: 3) // bufferSizeDB (24)
        decoderConfig += uint32(0) + uint32(0) // maxBitrate, avgBitrate
        decoderConfig += decoderSpecific
        let slConfig = descriptor(0x06, Data([0x02]))
        var es = Data([0x00, 0x00, 0x00]) // ES_ID (16) + flags (8)
        es += descriptor(0x04, decoderConfig) + slConfig
        return fullBox("esds", descriptor(0x03, es))
    }

    // MARK: - AC-3

    /// Build `dac3` from the first AC-3 syncframe (ETSI TS 102 366 §4.3/§F.4).
    static func dac3(fromSyncframe frame: Data) -> Data? {
        var bits = BitReader(frame)
        guard bits.read(16) == 0x0B77 else { return nil }
        bits.skip(16) // crc1
        let fscod = bits.read(2)
        let frmsizecod = bits.read(6)
        let bsid = bits.read(5)
        let bsmod = bits.read(3)
        let acmod = bits.read(3)
        guard bits.isValid, fscod != 3, frmsizecod < 38, bsid <= 8 else { return nil }
        if acmod & 0x1 != 0, acmod != 1 {
            bits.skip(2)
        } // cmixlev
        if acmod & 0x4 != 0 {
            bits.skip(2)
        } // surmixlev
        if acmod == 2 {
            bits.skip(2)
        } // dsurmod
        let lfeon = bits.read(1)
        guard bits.isValid else { return nil }

        var writer = BitWriter()
        writer.write(fscod, 2)
        writer.write(bsid, 5)
        writer.write(bsmod, 3)
        writer.write(acmod, 3)
        writer.write(lfeon, 1)
        writer.write(frmsizecod >> 1, 5) // bit_rate_code
        writer.write(0, 5) // reserved
        return fullBoxless("dac3", writer.data)
    }

    // MARK: - E-AC-3

    /// Build `dec3` from an E-AC-3 sample (ETSI TS 102 366 Annex E/F.6). One
    /// fMP4 sample is a sync window: an independent syncframe optionally
    /// followed by dependent substream syncframes; all must be declared.
    static func dec3(fromSample sample: Data) -> Data? {
        struct Substream {
            var fscod = 0, bsid = 0, bsmod = 0, acmod = 0, lfeon = 0
            var dependentCount = 0
            var chanLoc = 0
        }
        var independents: [Substream] = []
        var dataRateKbps = 0

        var offset = sample.startIndex
        while offset + 6 <= sample.endIndex {
            var bits = BitReader(sample[offset...])
            guard bits.read(16) == 0x0B77 else { break }
            let strmtyp = bits.read(2)
            bits.skip(3) // substreamid
            let frmsiz = bits.read(11)
            let fscod = bits.read(2)
            var numblkscod = 3
            if fscod == 3 {
                bits.skip(2) // fscod2; reduced rates always use 6 blocks
            } else {
                numblkscod = bits.read(2)
            }
            let acmod = bits.read(3)
            let lfeon = bits.read(1)
            let bsid = bits.read(5)
            guard bits.isValid, bsid > 10, bsid <= 16 else { return nil }
            bits.skip(5) // dialnorm
            if bits.read(1) == 1 {
                bits.skip(8)
            } // compre -> compr
            if acmod == 0 {
                bits.skip(5) // dialnorm2
                if bits.read(1) == 1 {
                    bits.skip(8)
                } // compr2e -> compr2
            }

            let frameBytes = (frmsiz + 1) * 2
            let blocks = [1, 2, 3, 6][numblkscod]

            if strmtyp == 1 {
                // Dependent substream: attach to the last independent one.
                guard !independents.isEmpty else { return nil }
                independents[independents.count - 1].dependentCount += 1
                if bits.read(1) == 1 { // chanmape
                    let chanmap = bits.read(16)
                    guard bits.isValid else { return nil }
                    independents[independents.count - 1].chanLoc |= Self.chanLoc(fromChanmap: chanmap)
                }
            } else {
                independents.append(Substream(fscod: fscod, bsid: bsid, bsmod: 0, acmod: acmod, lfeon: lfeon))
                if fscod != 3 {
                    let sampleRate = [48000, 44100, 32000][fscod]
                    let bitsPerSecond = frameBytes * 8 * sampleRate / (blocks * 256)
                    dataRateKbps += bitsPerSecond / 1000
                }
            }
            offset += frameBytes
        }
        guard !independents.isEmpty, independents.count <= 8 else { return nil }

        var writer = BitWriter()
        writer.write(min(dataRateKbps, 0x1FFF), 13)
        writer.write(independents.count - 1, 3)
        for sub in independents {
            writer.write(sub.fscod, 2)
            writer.write(sub.bsid, 5)
            writer.write(0, 1) // reserved
            writer.write(0, 1) // asvc
            writer.write(sub.bsmod, 3)
            writer.write(sub.acmod, 3)
            writer.write(sub.lfeon, 1)
            writer.write(0, 3) // reserved
            writer.write(min(sub.dependentCount, 15), 4)
            if sub.dependentCount > 0 {
                writer.write(sub.chanLoc, 9)
            } else {
                writer.write(0, 1) // reserved
            }
        }
        return fullBoxless("dec3", writer.data)
    }

    /// Map a dependent substream's 16-bit `chanmap` (transmission order: bit
    /// 15 = L … bit 1 = LFE2, bit 0 = LFE) to the `dec3` box's 9-bit
    /// `chan_loc` (TS 102 366 §F.6.1: bit 0 = Lc/Rc … bit 7 = Cvh, bit 8 =
    /// LFE2). The fields run in OPPOSITE bit orders and chan_loc skips
    /// chanmap's reserved bit 2, so no shift-and-mask relates them.
    static func chanLoc(fromChanmap chanmap: Int) -> Int {
        var chanLoc = 0
        for bit in 0 ... 7 { // Lc/Rc, Lrs/Rrs, Cs, Ts, Lsd/Rsd, Lw/Rw, Lvh/Rvh, Cvh
            if chanmap & (1 << (10 - bit)) != 0 {
                chanLoc |= 1 << bit
            }
        }
        if chanmap & 0x2 != 0 { // LFE2
            chanLoc |= 1 << 8
        }
        return chanLoc
    }

    // MARK: - FLAC

    /// Build `dfLa` from A_FLAC CodecPrivate: the "fLaC" magic followed by
    /// metadata blocks, which are exactly the box's payload.
    static func dfLa(fromCodecPrivate codecPrivate: Data) -> Data? {
        guard codecPrivate.count > 4,
              codecPrivate.prefix(4).elementsEqual("fLaC".utf8)
        else { return nil }
        let blocks = codecPrivate.dropFirst(4)
        // The first block must be STREAMINFO (type 0), 34 bytes of payload.
        guard blocks.count >= 38, blocks[blocks.startIndex] & 0x7F == 0 else { return nil }
        return fullBox("dfLa", Data(blocks))
    }

    // MARK: - Box helpers

    private static func fullBox(_ type: String, _ payload: Data) -> Data {
        var box = uint32(12 + payload.count)
        box += Data(type.utf8)
        box += Data(count: 4) // version 0, flags 0
        box += payload
        return box
    }

    /// dac3/dec3 are plain boxes, not full boxes.
    private static func fullBoxless(_ type: String, _ payload: Data) -> Data {
        uint32(8 + payload.count) + Data(type.utf8) + payload
    }

    private static func uint32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}

// MARK: - Bit-level readers/writers

struct BitReader {
    private let bytes: [UInt8]
    private var bitPosition = 0
    private(set) var isValid = true

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0 ..< count {
            let byteIndex = bitPosition >> 3
            guard byteIndex < bytes.count else {
                isValid = false
                return 0
            }
            let bit = (bytes[byteIndex] >> (7 - (bitPosition & 7))) & 1
            value = (value << 1) | Int(bit)
            bitPosition += 1
        }
        return value
    }

    mutating func skip(_ count: Int) {
        bitPosition += count
        if bitPosition > bytes.count * 8 {
            isValid = false
        }
    }
}

struct BitWriter {
    private(set) var data = Data()
    private var pending = 0
    private var pendingBits = 0

    mutating func write(_ value: Int, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            pending = (pending << 1) | ((value >> shift) & 1)
            pendingBits += 1
            if pendingBits == 8 {
                data.append(UInt8(pending))
                pending = 0
                pendingBits = 0
            }
        }
    }
}

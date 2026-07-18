import Foundation

/// Wraps trickplay JPEG thumbnails in fragmented MP4 so AVFoundation can
/// consume them as an HLS `mjpg` I-frame rendition
///
/// tvOS has no API for injecting scrub thumbnails into the system transport
/// bar, but its player natively renders I-frame renditions during scrubbing,
/// and the HLS authoring spec (6.17, appendix "I-frame image sequences")
/// permits image-based I-frame content: fMP4 fragments whose samples are raw
/// JPEGs under an `mjpg` sample entry. This muxer produces exactly that — an
/// initialization segment plus one single-sample fragment per thumbnail —
/// which `TrickplayLocalServer` serves alongside a rewritten master playlist.
///
/// Pure `Data` assembly with no networking or AVFoundation, so it is fully
/// unit-testable on the host.
public enum TrickplayIFrameMuxer {
    /// Movie timescale: 1 unit = 1ms, matching trickplay's ms intervals
    static let timescale = 1000

    // MARK: - Public segments

    /// The initialization segment (`ftyp` + `moov`) for an image sequence
    /// - Parameters:
    ///   - thumbnailWidth: Width in pixels of every thumbnail sample
    ///   - thumbnailHeight: Height in pixels of every thumbnail sample
    ///   - durationMilliseconds: Total duration the sequence spans
    public static func initializationSegment(
        thumbnailWidth: Int,
        thumbnailHeight: Int,
        durationMilliseconds: Int,
    ) -> Data {
        ftyp() + moov(
            width: thumbnailWidth,
            height: thumbnailHeight,
            durationMilliseconds: durationMilliseconds,
        )
    }

    /// One media segment (`moof` + `mdat`) carrying a single JPEG sample
    /// - Parameters:
    ///   - index: Zero-based thumbnail index; also drives the fragment's
    ///     sequence number and decode time
    ///   - durationMilliseconds: Time the thumbnail covers (the trickplay
    ///     interval)
    ///   - jpegData: The encoded JPEG for this thumbnail
    public static func mediaSegment(
        index: Int,
        durationMilliseconds: Int,
        jpegData: Data,
    ) -> Data {
        let mfhd = fullBox("mfhd", version: 0, flags: 0, payload: uint32(index + 1))

        // default-base-is-moof | default-sample-flags-present;
        // sample flags 0x02000000 = I-frame (depends on nothing, sync sample)
        let tfhd = fullBox("tfhd", version: 0, flags: 0x020020, payload: uint32(1) + uint32(0x0200_0000))
        let tfdt = fullBox("tfdt", version: 1, flags: 0, payload: uint64(index * durationMilliseconds))

        // data-offset-present | sample-duration-present | sample-size-present,
        // with the data offset patched in once the moof size is known
        let trunPayload = uint32(1) + int32(0) + uint32(durationMilliseconds) + uint32(jpegData.count)
        let trun = fullBox("trun", version: 0, flags: 0x000301, payload: trunPayload)

        let traf = box("traf", tfhd + tfdt + trun)
        var moof = box("moof", mfhd + traf)

        // The sample data starts right after moof and the mdat header
        let dataOffset = moof.count + 8
        // moof hdr (8) + mfhd + traf hdr (8) + tfhd + tfdt +
        // trun hdr (8) + fullbox hdr (4) + sample count (4)
        let offsetPosition = 8 + mfhd.count + 8 + tfhd.count + tfdt.count + 8 + 4 + 4
        moof.replaceSubrange(offsetPosition ..< offsetPosition + 4, with: int32(dataOffset))

        return moof + box("mdat", jpegData)
    }

    // MARK: - Init-segment boxes

    private static func ftyp() -> Data {
        box("ftyp", fourCC("iso6") + uint32(0) + fourCC("iso6") + fourCC("mp41") + fourCC("dash"))
    }

    private static func moov(width: Int, height: Int, durationMilliseconds: Int) -> Data {
        let dref = fullBox("dref", version: 0, flags: 0, payload: uint32(1) + fullBox("url ", version: 0, flags: 1, payload: Data()))
        let minf = box(
            "minf",
            fullBox("vmhd", version: 0, flags: 1, payload: Data(count: 8))
                + box("dinf", dref)
                + stbl(width: width, height: height),
        )
        let mdia = box("mdia", mdhd(durationMilliseconds: durationMilliseconds) + hdlr() + minf)
        let trak = box("trak", tkhd(width: width, height: height, durationMilliseconds: durationMilliseconds) + mdia)
        let trex = fullBox("trex", version: 0, flags: 0, payload: uint32(1) + uint32(1) + uint32(0) + uint32(0) + uint32(0))
        let mvex = box("mvex", fullBox("mehd", version: 0, flags: 0, payload: uint32(durationMilliseconds)) + trex)
        return box("moov", mvhd(durationMilliseconds: durationMilliseconds) + mvex + trak)
    }

    private static func mvhd(durationMilliseconds: Int) -> Data {
        var payload = uint32(0) + uint32(0) // creation, modification
        payload += uint32(timescale) + uint32(durationMilliseconds)
        payload += int32(0x0001_0000) // rate 1.0
        payload += Data([0x01, 0x00]) // volume 1.0
        payload += Data(count: 10) // reserved
        payload += identityMatrix()
        payload += Data(count: 24) // pre_defined
        payload += uint32(2) // next track id
        return fullBox("mvhd", version: 0, flags: 0, payload: payload)
    }

    private static func tkhd(width: Int, height: Int, durationMilliseconds: Int) -> Data {
        var payload = uint32(0) + uint32(0) // creation, modification
        payload += uint32(1) // track id
        payload += uint32(0) // reserved
        payload += uint32(durationMilliseconds)
        payload += Data(count: 8) // reserved
        payload += Data(count: 8) // layer, group, volume, reserved
        payload += identityMatrix()
        payload += uint32(width << 16) + uint32(height << 16)
        // enabled | in movie | in preview
        return fullBox("tkhd", version: 0, flags: 7, payload: payload)
    }

    private static func mdhd(durationMilliseconds: Int) -> Data {
        var payload = uint32(0) + uint32(0)
        payload += uint32(timescale) + uint32(durationMilliseconds)
        payload += Data([0x55, 0xC4, 0x00, 0x00]) // language 'und'
        return fullBox("mdhd", version: 0, flags: 0, payload: payload)
    }

    private static func hdlr() -> Data {
        let payload = uint32(0) + fourCC("vide") + Data(count: 12) + Data("VideoHandler\0".utf8)
        return fullBox("hdlr", version: 0, flags: 0, payload: payload)
    }

    private static func stbl(width: Int, height: Int) -> Data {
        let empty = uint32(0)
        return box(
            "stbl",
            stsd(width: width, height: height)
                + fullBox("stts", version: 0, flags: 0, payload: empty)
                + fullBox("stsc", version: 0, flags: 0, payload: empty)
                + fullBox("stsz", version: 0, flags: 0, payload: uint32(0) + uint32(0))
                + fullBox("stco", version: 0, flags: 0, payload: empty),
        )
    }

    /// The `mjpg` visual sample entry: JPEG is self-describing, so unlike
    /// H.264/HEVC there is no codec configuration box
    private static func stsd(width: Int, height: Int) -> Data {
        var entry = Data(count: 6) // reserved
        entry += uint16(1) // data_reference_index
        entry += Data(count: 16) // pre_defined / reserved
        entry += uint16(width) + uint16(height)
        entry += uint32(0x0048_0000) + uint32(0x0048_0000) // 72 dpi
        entry += uint32(0) // reserved
        entry += uint16(1) // frame_count
        entry += Data([0x04]) + Data("mjpg".utf8) + Data(count: 27) // compressorname
        entry += uint16(24) + Data([0xFF, 0xFF]) // depth, pre_defined -1
        let sampleEntry = box("mjpg", entry)
        return fullBox("stsd", version: 0, flags: 0, payload: uint32(1) + sampleEntry)
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
        let v = UInt16(value)
        return Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    private static func uint32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func int32(_ value: Int) -> Data {
        uint32(Int(UInt32(bitPattern: Int32(value))))
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

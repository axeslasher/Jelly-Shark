import Foundation

// Audio lifted out of a server-side audio-only HLS transcode (#249): the
// spike that muxes Jellyfin-transcoded AAC into the in-app remux so
// DTS/TrueHD-default sources can ride rung 1.
//
// Jellyfin serves `/Audio/{id}/main.m3u8` for MOVIE items (probed 2026-08-17
// against 10.11.11): 3-second MPEG-TS segments (whatever `segmentContainer`
// says), one ffmpeg run per seek, `-ss` applied exactly at the requested
// segment boundary, and — the load-bearing part — `-copyts`, so PES
// timestamps are absolute source timestamps on a 90 kHz clock, offset by a
// constant mux delay. Within a run, PES deltas are exactly
// `samplesPerFrame` worth of 90 kHz ticks per AAC frame: no drift, ever.
// The one wrinkle is encoder priming (measured 2048 samples, libfdk): a
// seek run declares its priming frames BELOW the seek point, while the
// from-zero run clamps its first PES timestamp to exactly the mux offset
// and absorbs the priming into the timeline (content measured ~43 ms late
// against declared PTS via beep-marker fixtures). `TranscodedAudioRun`
// encodes both measured rules.

public enum TransportStreamAudioError: Error, Equatable {
    /// Not 188-byte-aligned TS, or no PAT/PMT/AAC elementary stream found.
    case notAACTransportStream
    /// A PES header or ADTS frame did not parse.
    case malformed(String)
}

/// What one ADTS stream declares about itself — enough to build the fMP4
/// sample entry (`AudioSampleEntryConfiguration.aac`) and the sample grid.
public struct ADTSStreamInfo: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    /// Two-byte MPEG-4 AudioSpecificConfig synthesized from the ADTS header.
    public let audioSpecificConfig: Data
    /// Always 1024 for the AAC-LC these transcodes produce.
    public let samplesPerFrame: Int
}

/// One AAC access unit from a transcode segment: the raw payload (ADTS
/// header stripped) and the PES-declared presentation time.
public struct TranscodedAudioFrame: Sendable {
    public let data: Data
    /// Absolute source presentation time on the 90 kHz PES clock, including
    /// the server's constant mux offset (`TranscodedAudioRun.muxOffset90k`).
    public let pts90k: Int64
}

/// Extracts the AAC frames from one MPEG-TS audio segment.
public enum TransportStreamAudioExtractor {
    private static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    public static func extract(from ts: Data) throws -> (info: ADTSStreamInfo, frames: [TranscodedAudioFrame]) {
        let packets = try transportPackets(ts)
        let audioPID = try findAACPID(packets)

        // Reassemble the PID's PES packets: each starts at a
        // payload-unit-start packet and carries a PTS; ADTS frames never
        // straddle a PES boundary in ffmpeg's mux, but a frame routinely
        // straddles TS packets within one PES, so parse per reassembled PES.
        var frames: [TranscodedAudioFrame] = []
        var info: ADTSStreamInfo?
        var pesPayload = Data()
        var pesPTS: Int64?

        func flushPES() throws {
            guard let pts = pesPTS, !pesPayload.isEmpty else { return }
            let parsed = try adtsFrames(in: pesPayload)
            if info == nil {
                info = parsed.info
            }
            let ticksPerFrame = Int64(parsed.info.samplesPerFrame) * 90000 / Int64(parsed.info.sampleRate)
            for (i, payload) in parsed.payloads.enumerated() {
                frames.append(TranscodedAudioFrame(data: payload, pts90k: pts + Int64(i) * ticksPerFrame))
            }
            pesPayload.removeAll(keepingCapacity: true)
        }

        for packet in packets where packet.pid == audioPID {
            guard let payload = packet.payload else { continue }
            if packet.payloadUnitStart {
                try flushPES()
                let (pts, data) = try pesStart(payload)
                pesPTS = pts
                pesPayload = data
            } else if pesPTS != nil {
                pesPayload += payload
            }
        }
        try flushPES()

        guard let info, !frames.isEmpty else {
            throw TransportStreamAudioError.malformed("no audio frames in segment")
        }
        return (info, frames)
    }

    // MARK: - TS layer

    private struct TSPacket {
        let pid: Int
        let payloadUnitStart: Bool
        let payload: Data?
    }

    private static func transportPackets(_ ts: Data) throws -> [TSPacket] {
        guard !ts.isEmpty, ts.count % 188 == 0 else {
            throw TransportStreamAudioError.notAACTransportStream
        }
        var packets: [TSPacket] = []
        packets.reserveCapacity(ts.count / 188)
        var offset = ts.startIndex
        while offset < ts.endIndex {
            guard ts[offset] == 0x47 else { throw TransportStreamAudioError.notAACTransportStream }
            let pid = Int(ts[offset + 1] & 0x1F) << 8 | Int(ts[offset + 2])
            let payloadUnitStart = ts[offset + 1] & 0x40 != 0
            let adaptation = (ts[offset + 3] >> 4) & 0x3
            var payloadStart = offset + 4
            if adaptation & 0x2 != 0 {
                payloadStart += 1 + Int(ts[offset + 4])
            }
            let end = offset + 188
            let payload: Data? = (adaptation & 0x1 != 0 && payloadStart < end) ? ts[payloadStart ..< end] : nil
            packets.append(TSPacket(pid: pid, payloadUnitStart: payloadUnitStart, payload: payload))
            offset = end
        }
        return packets
    }

    /// PAT → PMT → the elementary PID with stream_type 0x0F (ADTS AAC).
    private static func findAACPID(_ packets: [TSPacket]) throws -> Int {
        func tableBody(_ payload: Data) -> Data? {
            // Pointer field, then the section header; body runs to the CRC.
            guard payload.count > 1 else { return nil }
            let start = payload.startIndex + 1 + Int(payload[payload.startIndex])
            guard start + 8 < payload.endIndex else { return nil }
            let sectionLength = Int(payload[start + 1] & 0x0F) << 8 | Int(payload[start + 2])
            let bodyStart = start + 8
            let bodyEnd = min(start + 3 + sectionLength - 4, payload.endIndex)
            guard bodyStart < bodyEnd else { return nil }
            return payload[bodyStart ..< bodyEnd]
        }

        var pmtPID: Int?
        for packet in packets where packet.pid == 0 && packet.payloadUnitStart {
            guard let payload = packet.payload, let body = tableBody(payload) else { continue }
            var i = body.startIndex
            while i + 4 <= body.endIndex {
                let program = Int(body[i]) << 8 | Int(body[i + 1])
                let pid = Int(body[i + 2] & 0x1F) << 8 | Int(body[i + 3])
                if program != 0 {
                    pmtPID = pid
                    break
                }
                i += 4
            }
            if pmtPID != nil {
                break
            }
        }
        guard let pmtPID else { throw TransportStreamAudioError.notAACTransportStream }

        for packet in packets where packet.pid == pmtPID && packet.payloadUnitStart {
            guard let payload = packet.payload, let body = tableBody(payload) else { continue }
            guard body.count >= 4 else { continue }
            let programInfoLength = Int(body[body.startIndex + 2] & 0x0F) << 8 | Int(body[body.startIndex + 3])
            var i = body.startIndex + 4 + programInfoLength
            while i + 5 <= body.endIndex {
                let streamType = body[i]
                let pid = Int(body[i + 1] & 0x1F) << 8 | Int(body[i + 2])
                let esInfoLength = Int(body[i + 3] & 0x0F) << 8 | Int(body[i + 4])
                if streamType == 0x0F {
                    return pid
                }
                i += 5 + esInfoLength
            }
        }
        throw TransportStreamAudioError.notAACTransportStream
    }

    /// Parse the head of a PES packet: the PTS and the elementary payload
    /// after the header.
    private static func pesStart(_ payload: Data) throws -> (pts: Int64, data: Data) {
        let s = payload.startIndex
        guard payload.count >= 14,
              payload[s] == 0, payload[s + 1] == 0, payload[s + 2] == 1,
              payload[s + 3] & 0xE0 == 0xC0 // audio stream_id
        else { throw TransportStreamAudioError.malformed("PES start without audio header") }
        guard payload[s + 7] & 0x80 != 0 else {
            throw TransportStreamAudioError.malformed("PES without PTS")
        }
        let headerLength = Int(payload[s + 8])
        let p = s + 9
        let pts = Int64(payload[p] >> 1 & 0x7) << 30
            | Int64(payload[p + 1]) << 22
            | Int64(payload[p + 2] >> 1) << 15
            | Int64(payload[p + 3]) << 7
            | Int64(payload[p + 4] >> 1)
        let dataStart = s + 9 + headerLength
        guard dataStart <= payload.endIndex else {
            throw TransportStreamAudioError.malformed("PES header past packet end")
        }
        return (pts, payload[dataStart...])
    }

    // MARK: - ADTS layer

    private static func adtsFrames(in data: Data) throws -> (info: ADTSStreamInfo, payloads: [Data]) {
        var payloads: [Data] = []
        var info: ADTSStreamInfo?
        var i = data.startIndex
        while i < data.endIndex {
            guard i + 7 <= data.endIndex, data[i] == 0xFF, data[i + 1] & 0xF0 == 0xF0 else {
                throw TransportStreamAudioError.malformed("ADTS desync")
            }
            let protectionAbsent = data[i + 1] & 0x1 != 0
            let profile = Int(data[i + 2] >> 6)
            let samplingIndex = Int(data[i + 2] >> 2 & 0xF)
            let channelConfiguration = Int(data[i + 2] & 0x1) << 2 | Int(data[i + 3] >> 6)
            let frameLength = Int(data[i + 3] & 0x3) << 11 | Int(data[i + 4]) << 3 | Int(data[i + 5] >> 5)
            let headerLength = protectionAbsent ? 7 : 9
            guard samplingIndex < sampleRates.count, channelConfiguration >= 1,
                  frameLength > headerLength, i + frameLength <= data.endIndex
            else { throw TransportStreamAudioError.malformed("ADTS header out of range") }
            if info == nil {
                // AudioSpecificConfig: audioObjectType(5) = profile + 1,
                // samplingFrequencyIndex(4), channelConfiguration(4).
                let objectType = profile + 1
                let asc = Data([
                    UInt8(objectType << 3 | samplingIndex >> 1),
                    UInt8((samplingIndex & 0x1) << 7 | channelConfiguration << 3),
                ])
                info = ADTSStreamInfo(
                    sampleRate: sampleRates[samplingIndex],
                    channelCount: channelConfiguration == 7 ? 8 : channelConfiguration,
                    audioSpecificConfig: asc,
                    samplesPerFrame: 1024,
                )
            }
            payloads.append(data[(i + headerLength) ..< (i + frameLength)])
            i += frameLength
        }
        guard let info else { throw TransportStreamAudioError.malformed("empty PES payload") }
        return (info, payloads)
    }
}

/// One continuous ffmpeg run of the server's audio transcode: the alignment
/// rules that turn PES-stamped frames into an exact intrinsic-duration
/// sample grid anchored at the run's requested start.
public enum TranscodedAudioRun {
    /// The server mux's constant timestamp offset: every PES PTS is source
    /// time plus this. Measured exactly 10 s on Jellyfin 10.11.11
    /// (jellyfin-ffmpeg 7.1.4 mpegts mux); a session logs the deviation if
    /// its stream disagrees, which is the signal to derive it at runtime
    /// instead of pinning it.
    public static let muxOffset90k: Int64 = 900_000

    /// Encoder priming the FROM-ZERO run absorbs into its timeline: the
    /// mpegts mux clamps the run's first PES timestamp to `muxOffset90k`
    /// exactly, so the priming frames are indistinguishable from content by
    /// PTS and must be dropped by count. 2048 samples = 2 frames, measured
    /// for libfdk_aac (jellyfin-ffmpeg's AAC encoder). Seek runs need no
    /// constant: they declare priming honestly, below the seek point.
    public static let assumedFromZeroPrimingFrames = 2

    /// How many frames at the head of a fresh run are encoder priming, from
    /// the run's first declared PTS and its requested start time.
    ///
    /// - A seek run declares priming below the seek point: drop every frame
    ///   that ends at or before `start + muxOffset` (beep-fixture verified:
    ///   the first kept frame's content starts exactly at the seek point).
    /// - The from-zero run is recognized by its clamped first PTS
    ///   (== `muxOffset90k` exactly) and gets the constant drop.
    public static func primingFrameCount(
        firstPTS90k: Int64,
        runStartTicks90k: Int64,
        ticksPerFrame90k: Int64,
    ) -> Int {
        if runStartTicks90k == 0, firstPTS90k == muxOffset90k {
            return assumedFromZeroPrimingFrames
        }
        let target = runStartTicks90k + muxOffset90k
        guard firstPTS90k < target else { return 0 }
        return Int((target - firstPTS90k + ticksPerFrame90k - 1) / ticksPerFrame90k)
    }

    /// Where a run's sample grid is anchored, in sample-rate ticks.
    ///
    /// Normally the requested boundary — the first kept frame lands on it
    /// exactly (probe-verified). But the server's `-ss` can land late on the
    /// source audio (device-measured +20.5 ms at a far seek), and anchoring
    /// the grid at the boundary would then play the whole run's audio early
    /// by that much. Past half a frame, the declared time wins: the anchor
    /// snaps to the first kept frame's own PTS. `firstKeptPTS90k` is nil
    /// when the run's declared clock cannot be trusted (the from-zero
    /// clamp), which keeps the boundary anchor.
    public static func anchorTicks(
        firstKeptPTS90k: Int64?,
        runStartTicks90k: Int64,
        ticksPerFrame90k: Int64,
        sampleRate: Int,
    ) -> Int64 {
        let rate = Int64(sampleRate)
        let boundary = runStartTicks90k * rate / 90000
        guard let firstKeptPTS90k else { return boundary }
        let deviation90k = firstKeptPTS90k - muxOffset90k - runStartTicks90k
        guard abs(deviation90k) > ticksPerFrame90k / 2 else { return boundary }
        return ((firstKeptPTS90k - muxOffset90k) * rate + 45000) / 90000
    }
}

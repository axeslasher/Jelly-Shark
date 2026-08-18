import Foundation
import JellyfinKit
import Network
import OSLog

/// A loopback HTTP server presenting an in-app Matroska remux as a
/// master-less HLS media playlist (#172).
///
/// This exists because AVFoundation's HDR eligibility gate (#146) fires at
/// HLS variant selection over DECLARED master attributes: a master
/// declaring 4K PQ is refused on an SDR display (`-11868`, underlying
/// CoreMedia `-17223`) before a single segment is fetched — but a media
/// playlist with no master never reaches variant selection, and genuine
/// 4K PQ segments reached `readyToPlay` and buffered on the same device
/// (measured 2026-08-02). The progressive alternative is equally settled:
/// AVFoundation's file reader ignores `sidx` and linear-scans the whole
/// file, so the manifest-driven stack is the only reader that can be told
/// where the fragments are — and the playlist is how it is told.
///
/// Routes are exactly the URIs `HLSSegmentPlan.mediaPlaylist()` references:
/// `/media.m3u8`, `/init.mp4`, `/seg<n>.m4s`. Segments are remuxed on
/// demand from ranged reads of the original MKV.
final class RemuxHLSServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let demuxer: MatroskaDemuxer
    private let remuxer: MatroskaFMP4Remuxer
    private let plan: HLSSegmentPlan
    private let initSegment: Data
    private let playlist: Data

    private let http = LoopbackHTTPListener(
        queueLabel: "com.justinlascelle.jellyshark.remux-hls-server",
        logPrefix: "[remux-hls]",
    )
    private var queue: DispatchQueue {
        http.queue
    }

    /// Called at most once, off the main actor, when segment production
    /// fails with a deterministic error — the file's structure, not the
    /// network — so no amount of AVPlayer retrying can heal it and the
    /// delivery should rebuild on its next rung (#176's failure posture).
    var onUnrecoverableSegmentFailure: (@Sendable () -> Void)?
    /// One-shot guard for the callback; accessed on `queue`.
    private var unrecoverableFailureReported = false

    /// Startup diagnosis instrumentation: the request pattern is the one
    /// signal that distinguishes a healthy session (playlist + init + a
    /// steady forward march of segments) from a pathological one. Numbered
    /// requests with elapsed time make that legible in one glance at the
    /// console.
    private let startedAt = ContinuousClock.now
    private var requestCount = 0

    /// Segments already produced, newest last. Playback fetches forward,
    /// so a shallow cache absorbs stall-retry re-requests; bounded because
    /// the plan caps how many source bytes a merged span may cover
    /// (`HLSSegmentPlan.defaultMaxMergedSpanBytes`).
    private var segmentCache: [(index: Int, data: Data)] = []
    private static let segmentCacheLimit = 2

    /// Productions in flight, so overlapping requests share one remux — a
    /// span remux is expensive enough that racing it doubles serve latency
    /// (measured on the 2026-08-02 progressive device round).
    private var segmentTasks: [Int: Task<Data, Error>] = [:]

    /// ffmpeg prepends this `styp` to every fMP4 media segment. Mirror the
    /// device-verified shape byte for byte — this branch has twice paid a
    /// device round for deviating from what ffmpeg emits.
    private static let styp = Data([
        0x00, 0x00, 0x00, 0x18, 0x73, 0x74, 0x79, 0x70, // size 24, 'styp'
        0x6D, 0x73, 0x64, 0x68, // major brand 'msdh'
        0x00, 0x00, 0x00, 0x00, // minor version
        0x6D, 0x73, 0x64, 0x68, 0x6D, 0x73, 0x69, 0x78, // compatible 'msdh' 'msix'
    ])

    init(demuxer: MatroskaDemuxer, remuxer: MatroskaFMP4Remuxer, plan: HLSSegmentPlan, initSegment: Data) {
        self.demuxer = demuxer
        self.remuxer = remuxer
        self.plan = plan
        self.initSegment = initSegment
        playlist = Data(plan.mediaPlaylist().utf8)
        http.route = { [weak self] target, connection in
            self?.route(target, on: connection)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start listening on an ephemeral loopback port.
    /// - Returns: The media playlist URL, or nil if the listener could not
    ///   start or the calling task was cancelled.
    func start() async -> URL? {
        guard let port = await http.start() else { return nil }
        Self.logger.info("[remux-hls] listening on 127.0.0.1:\(port) (\(self.plan.segments.count) segments, init \(self.initSegment.count) bytes)")
        if let shape = Self.probeMasterShape {
            Self.logger.warning("[remux-hls] #226 PROBE ACTIVE: playing master shape \(shape, privacy: .public) instead of the media playlist")
            return URL(string: "http://127.0.0.1:\(port)/probe\(shape).m3u8")
        }
        return URL(string: "http://127.0.0.1:\(port)/\(HLSSegmentPlan.playlistPath)")
    }

    // MARK: - #226 spike probe (temporary scaffolding — delete with the spike)

    /// The #146 gate refuses any master declaring 4K attributes, which is why
    /// this delivery is master-less. #226 needs a master (audio rendition
    /// groups only exist there), and its spike question is whether a master
    /// that declares *less* slips past the gate. These probe shapes bisect
    /// that on device, selected by scheme launch argument
    /// `-remuxProbeMaster <shape>`:
    ///
    ///   0  bare master: one variant, BANDWIDTH only. Failed -12927 on the
    ///      4K DV/FLAC session (round 1); whether the variant playlist was
    ///      fetched first was NOT recorded that round — rerun with the
    ///      forensics before citing it.
    ///   1  shape 0 + CODECS derived from the session's own tracks. Failed
    ///      -12927 on the 4K DV/FLAC session AFTER media.m3u8 + init.mp4
    ///      were fetched (rounds 2-4; CODECS content, tier, and FLAC
    ///      carriage all bisected irrelevant there).
    ///   2  shape 1 + a muxed audio rendition group (no URI — the audio is
    ///      declared as carried in the variant, so no audio-only segments
    ///      are needed to probe the shape)
    ///   3  shape 2 + truthful RESOLUTION (from the track header),
    ///      VIDEO-RANGE (default PQ; `-remuxProbeVideoRange <PQ|HLG|SDR|off>`
    ///      overrides or omits it), and FRAME-RATE — complete for the
    ///      attributes under test, not spec-conforming (AVERAGE-BANDWIDTH
    ///      and multiple bitrates are absent). The decisive cells were
    ///      VIDEO-RANGE=off and the false SDR declaration over PQ content:
    ///      both still fetched the init segment and failed -12927, proving
    ///      the content check authoritative — while the same shapes play
    ///      over SDR and HLG content. `-remuxProbeResolution <WxH>`
    ///      likewise overrides the truthful resolution (a lying 1920x1080
    ///      over 4K also failed only after the init fetch).
    /// Internal, not private: `AVFoundationPlayerEngine` gates its probe-only
    /// failure forensics on this too.
    static var probeMasterShape: Int? {
        // The scheme's Test action inherits the Run arguments, so a probe
        // shape left enabled for a device round would otherwise activate
        // inside the simulator suite and fail RemuxHLSServerTests. Never arm
        // in a test process.
        guard NSClassFromString("XCTestCase") == nil,
              let raw = UserDefaults.standard.string(forKey: "remuxProbeMaster"),
              let shape = Int(raw), (0 ... 3).contains(shape)
        else { return nil }
        return shape
    }

    /// `-remuxProbeCodecs <string>` replaces the derived CODECS attribute
    /// verbatim, so a round can bisect the attribute's content (drop the
    /// audio entry, mask the tier) without a rebuild. Round 2 (2026-08-17)
    /// motivated this: the derived "hvc1.2.4.H153.B0,fLaC" master PASSED
    /// parse and variant selection — media playlist and init segment were
    /// fetched — and the item then failed during pipeline setup with no
    /// segment ever requested, so the suspect is the attribute's content,
    /// not the master's existence.
    private static var probeCodecsOverride: String? {
        UserDefaults.standard.string(forKey: "remuxProbeCodecs")
    }

    /// `-remuxProbeVideoOnly YES` (with a probe shape active) drops the
    /// audio track from the session before the remuxer is built (see
    /// `StreamDelivery.prepareRemuxHLS`). Round 3 (2026-08-17) motivated
    /// this: every master shape over 4K PQ content — CODECS present,
    /// absent, video-only, tier-masked — failed with the same -12927 the
    /// #146 gate originally surfaced, after the media playlist and init
    /// segment were fetched. The leading model is a second gate layer that
    /// verifies fetched CONTENT (the init segment's 3840x2160/PQ), which
    /// FLAC carriage cannot explain but this run can distinguish: video-only
    /// still failing confirms the content gate; video-only playing
    /// implicates the FLAC track.
    static var probeVideoOnly: Bool {
        probeMasterShape != nil && UserDefaults.standard.bool(forKey: "remuxProbeVideoOnly")
    }

    /// `-remuxProbeForceEligible YES` (with a probe shape active) lets an
    /// SDR source take the remux rung, which production eligibility never
    /// allows. Round 5 (2026-08-17) motivated this: every undeclaring
    /// master over HDR content — 1080p and 4K, ±FLAC, ±DV — failed -12927
    /// after the init segment was fetched, leaving two rival explanations:
    /// the gate discovers PQ in the fetched content, or our variant shape
    /// is structurally rejected under any master. SDR content under the
    /// same master separates them: a pass convicts PQ discovery; a -12927
    /// failure convicts structure (and structure might be fixable).
    static var probeForceEligible: Bool {
        probeMasterShape != nil && UserDefaults.standard.bool(forKey: "remuxProbeForceEligible")
    }

    /// Peak declared bits per second across the plan's spans. The spec
    /// requires BANDWIDTH on every variant, and it must be the peak rate —
    /// under-declaring is itself a gate variable this probe should not vary.
    private var probePeakBandwidth: Int {
        let peak = plan.segments.compactMap { segment -> Double? in
            guard segment.durationSeconds > 0 else { return nil }
            let bytes = segment.clusterEndBound - segment.clusterOffset
            return Double(bytes) * 8 / segment.durationSeconds
        }.max() ?? 8_000_000
        return Int(peak)
    }

    private func probeMaster(shape: Int) -> Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        // NOTE: the estimate divides raw source-span bytes (all Matroska
        // tracks + container overhead) by duration, so it overstates the
        // served fMP4 peak on multi-track sources. Negligible on the
        // synthetic probe sources, whose only tracks are the carried two.
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(probePeakBandwidth)"
        if shape >= 1, let codecs = Self.probeCodecsOverride ?? probeCodecsAttribute {
            streamInf += ",CODECS=\"\(codecs)\""
        }
        if shape >= 2 {
            lines.append(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Default",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES"#)
            streamInf += #",AUDIO="main""#
        }
        if shape >= 3 {
            let video = remuxer.tracks.video
            let resolution = UserDefaults.standard.string(forKey: "remuxProbeResolution")
                ?? "\(video.pixelWidth ?? 0)x\(video.pixelHeight ?? 0)"
            streamInf += ",RESOLUTION=\(resolution)"
            // `-remuxProbeVideoRange <PQ|HLG|SDR|off>` — defaults to PQ
            // (hardcoded rather than derived because MatroskaTrack carries
            // no transfer-function field). "off" omits the attribute: with
            // every OTHER attribute present, that is the
            // complete-but-innocuous cell — if init is fetched only to fill
            // in missing attributes, this master might skip content
            // inspection entirely.
            let range = UserDefaults.standard.string(forKey: "remuxProbeVideoRange") ?? "PQ"
            if range.lowercased() != "off" {
                streamInf += ",VIDEO-RANGE=\(range)"
            }
            if let frameDurationNs = video.defaultDurationNs, frameDurationNs > 0 {
                streamInf += ",FRAME-RATE=\(String(format: "%.3f", 1e9 / Double(frameDurationNs)))"
            }
        }
        lines.append(streamInf)
        lines.append(HLSSegmentPlan.playlistPath)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// RFC 6381 CODECS for everything the variant's segments carry, derived
    /// from the session's own tracks. Matroska stores the `hvcC`/`avcC`
    /// record verbatim as CodecPrivate (spike finding 1 in
    /// `MatroskaFMP4Remuxer`), so the video string transliterates it
    /// directly; audio maps from the Matroska codec ID the same way
    /// `AudioSampleEntryConfiguration` picks its sample entry.
    private var probeCodecsAttribute: String? {
        var entries: [String] = []
        if let video = Self.probeVideoCodecString(for: remuxer.tracks.video) {
            entries.append(video)
        }
        if let track = remuxer.tracks.audio, let audio = Self.probeAudioCodecString(for: track) {
            entries.append(audio)
        }
        return entries.isEmpty ? nil : entries.joined(separator: ",")
    }

    private static func probeVideoCodecString(for track: MatroskaTrack) -> String? {
        guard let codecPrivate = track.codecPrivate else { return nil }
        let bytes = [UInt8](codecPrivate)
        switch track.codecID {
        case "V_MPEGH/ISO/HEVC":
            // ISO 14496-15 Annex E: hvc1.<space><profile>.<compat flags,
            // reversed bit order, hex>.<L|H><level>.<constraint bytes, hex,
            // trailing zeros dropped>. All fields come from hvcC bytes 1-12.
            guard bytes.count >= 13 else { return nil }
            let profileSpace = bytes[1] >> 6
            let tier = (bytes[1] >> 5) & 1
            let profileIDC = bytes[1] & 0x1F
            var compat: UInt32 = 0
            for i in 0 ..< 32 where (bytes[2 + i / 8] >> (7 - i % 8)) & 1 == 1 {
                compat |= 1 << i
            }
            var constraints = Array(bytes[6 ... 11])
            while constraints.last == 0 {
                constraints.removeLast()
            }
            var s = "hvc1."
            if profileSpace > 0 {
                s += String(UnicodeScalar(64 + profileSpace)) // A/B/C
            }
            s += "\(profileIDC).\(String(compat, radix: 16, uppercase: true))."
            s += (tier == 0 ? "L" : "H") + "\(bytes[12])"
            for constraint in constraints {
                s += String(format: ".%02X", constraint)
            }
            return s
        case "V_MPEG4/ISO/AVC":
            // avc1.PPCCLL: avcC profile, constraint-flags, and level bytes.
            guard bytes.count >= 4 else { return nil }
            return String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
        default:
            return nil
        }
    }

    private static func probeAudioCodecString(for track: MatroskaTrack) -> String? {
        switch track.codecID {
        case "A_AAC":
            // Object type is the AudioSpecificConfig's top 5 bits (31
            // escapes to an extended type in the next 6).
            guard let asc = track.codecPrivate.map({ [UInt8]($0) }), let first = asc.first else {
                return "mp4a.40.2"
            }
            var objectType = Int(first >> 3)
            if objectType == 31, asc.count >= 2 {
                objectType = 32 + ((Int(first) & 0x07) << 3) + Int(asc[1] >> 5)
            }
            return "mp4a.40.\(objectType)"
        case "A_AC3":
            return "ac-3"
        case "A_EAC3":
            return "ec-3"
        case "A_FLAC":
            return "fLaC"
        default:
            return nil
        }
    }

    func stop() {
        http.stop()
        // Cancel in-flight productions too: each rides ranged URLSession
        // reads, so an abandoned one would otherwise keep pulling span-sized
        // data from the origin after the session is gone.
        let tasks = queue.sync { () -> [Task<Data, Error>] in
            defer { segmentTasks.removeAll() }
            return Array(segmentTasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Routing (on the listener queue)

    private func route(_ target: String?, on connection: NWConnection) {
        guard let target else {
            http.send(status: "404 Not Found", on: connection)
            return
        }

        requestCount += 1
        let request = requestCount
        let elapsed = ContinuousClock.now - startedAt
        let path = String(target.dropFirst())
        Self.logger.info("[remux-hls] #\(request) +\(elapsed, privacy: .public) GET \(path, privacy: .public)")

        if path == HLSSegmentPlan.playlistPath {
            http.send(body: playlist, contentType: "application/vnd.apple.mpegurl", on: connection)
        } else if let shape = Self.probeMasterShape, path == "probe\(shape).m3u8" {
            let master = probeMaster(shape: shape)
            // The exact served text, so a rejection is diagnosable from the
            // console without guessing what the shape resolved to.
            Self.logger.warning("[remux-hls] #226 probe master shape \(shape, privacy: .public):\n\(String(decoding: master, as: UTF8.self), privacy: .public)")
            http.send(body: master, contentType: "application/vnd.apple.mpegurl", on: connection)
        } else if path == HLSSegmentPlan.initSegmentPath {
            http.send(body: initSegment, contentType: "video/mp4", on: connection)
        } else if let index = HLSSegmentPlan.segmentIndex(fromPath: path), plan.segments.indices.contains(index) {
            Task { await self.serveSegment(index, request: request, on: connection) }
        } else {
            Self.logger.warning("[remux-hls] 404 \(path, privacy: .public)")
            http.send(status: "404 Not Found", on: connection)
        }
    }

    // MARK: - Serving

    private func serveSegment(_ index: Int, request: Int, on connection: NWConnection) async {
        let data: Data
        do {
            data = try await segment(at: index)
        } catch {
            // Nothing has been sent yet, so the honest failure is a 500:
            // AVPlayer retries or stalls, and nothing corrupt is ever
            // served. What happens next depends on the error's class: a
            // demux/remux error is the file's structure and will fail
            // identically on every retry, so it demotes the delivery; a
            // network error can heal, so the retries are left to run.
            Self.logger.warning("[remux-hls] segment \(index) failed: \(error, privacy: .public)")
            if error is MatroskaError || error is MatroskaFMP4Remuxer.RemuxError {
                reportUnrecoverableFailure()
            }
            http.send(status: "500 Internal Server Error", on: connection)
            return
        }
        Self.logger.info("[remux-hls] #\(request) 200 seg\(index) \(data.count) bytes")
        http.send(body: data, contentType: "video/iso.segment", on: connection)
    }

    private func reportUnrecoverableFailure() {
        let firstReport = queue.sync { () -> Bool in
            defer { unrecoverableFailureReported = true }
            return !unrecoverableFailureReported
        }
        if firstReport {
            onUnrecoverableSegmentFailure?()
        }
    }

    private func segment(at index: Int) async throws -> Data {
        if let cached = queue.sync(execute: { segmentCache.first { $0.index == index }?.data }) {
            return cached
        }
        let (task, isProducer) = queue.sync { () -> (Task<Data, Error>, Bool) in
            if let inFlight = segmentTasks[index] {
                return (inFlight, false)
            }
            let task = Task { [demuxer, remuxer, plan] in
                let segment = plan.segments[index]
                let started = ContinuousClock.now
                let span = try await demuxer.readClusters(from: segment.clusterOffset, to: segment.clusterEndBound)
                // The next span's opening cluster carries any straddling
                // GOP's tail frames; the remuxer re-partitions at keyframes
                // so fragment timelines tile (#99).
                var nextSpanHead: MatroskaCluster?
                if index + 1 < plan.segments.count {
                    let next = plan.segments[index + 1]
                    nextSpanHead = try await demuxer.readFirstCluster(at: next.clusterOffset, endBound: next.clusterEndBound)
                }
                let fragment = try remuxer.makeFragment(sequence: index + 1, cluster: span, nextSpanHead: nextSpanHead)
                Self.logger.info("[remux-hls] segment \(index) produced: \(fragment.count) bytes in \(ContinuousClock.now - started, privacy: .public)")
                return Self.styp + fragment
            }
            segmentTasks[index] = task
            return (task, true)
        }
        defer {
            if isProducer {
                queue.sync { segmentTasks[index] = nil }
            }
        }
        let produced = try await task.value
        if isProducer {
            queue.sync {
                segmentCache.append((index, produced))
                if segmentCache.count > Self.segmentCacheLimit {
                    segmentCache.removeFirst()
                }
            }
        }
        return produced
    }
}

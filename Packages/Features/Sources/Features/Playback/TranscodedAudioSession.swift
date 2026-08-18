import Foundation
import JellyfinKit
import OSLog

/// The server-sourced audio half of an external-audio remux session (#249):
/// fetches Jellyfin's audio-only HLS transcode of the session's default
/// track, aligns each ffmpeg run to its requested start
/// (`TranscodedAudioRun`), and re-times the AAC frames onto the intrinsic
/// 1024-sample grid — the re-timing whose effect on the copy variant's
/// frameskip is what the spike's device round measures.
///
/// The server serves fixed ~3-second MPEG-TS segments; a request outside the
/// current run restarts ffmpeg with `-ss` at the nearest earlier segment
/// boundary, which is how seeks re-anchor. Frames are indexed on one global
/// grid per run — frame `g` occupies exactly
/// `[anchor + g·1024, anchor + (g+1)·1024)` in sample-rate ticks — so
/// consecutive remux spans tile with zero quantization by construction,
/// whatever the server's millisecond-rounded timestamps said.
actor TranscodedAudioSession {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let stream: AudioHLSStream
    private let urlSession: URLSession

    /// Parsed from the playlist: each server segment's start and length in
    /// server ticks (100 ns).
    private var segmentStartTicks10M: [Int64] = []
    private var segmentLengthTicks10M: [Int64] = []
    private var totalDurationTicks10M: Int64 = 0

    private(set) var info: ADTSStreamInfo?

    // MARK: Current run

    /// Server segment index the current ffmpeg run was started at.
    private var runStartSegment = 0
    /// The run's anchor in sample-rate ticks: the exact source time of grid
    /// index 0, after priming is dropped.
    private var anchorTicks: Int64 = 0
    /// Next server segment this run will fetch.
    private var nextSegment = 0
    /// Buffered raw AAC payloads for grid indices
    /// `bufferBase ..< bufferBase + buffer.count`.
    private var buffer: [Data] = []
    private var bufferBase = 0
    /// Where the run's declared PES clock should be at the next fetched
    /// frame — the drift detector's state, robust to the from-zero run's
    /// clamped base.
    private var nextExpectedPTS90k: Int64?

    /// How far past buffered coverage a window may start before the session
    /// re-seeks instead of fetching forward through the gap.
    private static let forwardJumpThresholdSeconds = 12.0
    /// Frames kept behind the last consumed window, so a stall-retry
    /// re-request of the previous span never forces a server re-seek.
    private static let keepBackSeconds = 8.0

    init(stream: AudioHLSStream) {
        self.stream = stream
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    /// Fetch the playlist and the first segment; returns what the transcode
    /// declares about itself, which is what the init segment needs. Throwing
    /// here is the delivery's cue to descend the ladder before anything is
    /// served.
    func start() async throws -> ADTSStreamInfo {
        let (data, response) = try await urlSession.data(from: stream.playlistURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try parsePlaylist(String(decoding: data, as: UTF8.self))
        try await startRun(at: 0)
        guard let info else { throw TransportStreamAudioError.malformed("no stream info") }
        Self.logger.info("[remux-audio] session up: \(self.segmentStartTicks10M.count) server segments, \(info.sampleRate) Hz, \(info.channelCount) ch")
        return info
    }

    /// The audio track fragment covering `[windowStartMS, windowEndMS)` in
    /// the remux plan's millisecond ticks; nil window end means to the end
    /// of the transcode. Returns nil when no frames land in the window.
    func fragment(
        windowStartMS: Int64,
        windowEndMS: Int64?,
        trackID: Int,
    ) async throws -> FMP4Muxer.TrackFragment? {
        guard let info else { throw TransportStreamAudioError.malformed("session not started") }
        let rate = Int64(info.sampleRate)
        let spf = Int64(info.samplesPerFrame)
        let startTicks = windowStartMS * rate / 1000
        let endTicks = windowEndMS.map { $0 * rate / 1000 }
            ?? (totalDurationTicks10M * rate / 10_000_000)

        // Re-seek when the window starts before the buffered floor or far
        // past coverage; otherwise the run already covers it or fetching
        // forward will.
        let bufferFloor = anchorTicks + Int64(bufferBase) * spf
        let coverageEnd = anchorTicks + Int64(bufferBase + buffer.count) * spf
        let jump = Int64(Self.forwardJumpThresholdSeconds * Double(rate))
        if startTicks < bufferFloor || startTicks > coverageEnd + jump {
            try await startRun(at: segmentIndex(coveringTicks: startTicks, rate: rate))
        }

        while anchorTicks + Int64(bufferBase + buffer.count) * spf < endTicks,
              nextSegment < segmentStartTicks10M.count
        {
            try await fetchNextSegment()
        }

        // Frames whose grid slot STARTS inside the window; the window
        // boundaries partition the grid, so consecutive spans share no frame.
        let firstIndex = max(Int64(bufferBase), ceilDiv(startTicks - anchorTicks, spf))
        var endIndex = ceilDiv(endTicks - anchorTicks, spf)
        endIndex = min(endIndex, Int64(bufferBase + buffer.count))
        guard firstIndex < endIndex else { return nil }

        let payloads = buffer[(Int(firstIndex) - bufferBase) ..< (Int(endIndex) - bufferBase)]
        var data = Data(capacity: payloads.reduce(0) { $0 + $1.count })
        for payload in payloads {
            data.append(payload)
        }
        let samples = payloads.map {
            FMP4Muxer.Sample(duration: Int(spf), size: $0.count, isSync: true)
        }
        trim(before: firstIndex - Int64(Self.keepBackSeconds * Double(rate)) / spf)
        return FMP4Muxer.TrackFragment(
            trackID: trackID,
            baseDecodeTime: anchorTicks + firstIndex * spf,
            samples: samples,
            data: data,
            isVideo: false,
        )
    }

    // MARK: - Runs

    private func startRun(at segment: Int) async throws {
        runStartSegment = segment
        nextSegment = segment
        buffer.removeAll()
        bufferBase = 0
        anchorTicks = 0 // set by the first fetch, which knows the sample rate
        try await fetchNextSegment()
    }

    private func fetchNextSegment() async throws {
        let index = nextSegment
        guard let url = stream.segmentURL(
            index: index,
            runtimeTicks: segmentStartTicks10M[index],
            segmentLengthTicks: segmentLengthTicks10M[index],
        ) else { throw URLError(.badURL) }
        let (data, response) = try await urlSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let (info, frames) = try TransportStreamAudioExtractor.extract(from: data)
        if self.info == nil {
            self.info = info
        }
        let rate = Int64(info.sampleRate)
        let spf = Int64(info.samplesPerFrame)
        let ticksPerFrame90k = spf * 90000 / rate

        var payloads = frames.map(\.data)
        if index == runStartSegment {
            // Head of a fresh ffmpeg run: drop encoder priming and anchor
            // the grid at the run's requested start.
            let runStart90k = segmentStartTicks10M[index] * 9 / 1000
            let priming = TranscodedAudioRun.primingFrameCount(
                firstPTS90k: frames.first?.pts90k ?? 0,
                runStartTicks90k: runStart90k,
                ticksPerFrame90k: ticksPerFrame90k,
            )
            payloads.removeFirst(min(priming, payloads.count))
            // Anchor at the requested boundary, unless the first kept
            // frame's declared time disagrees past half a frame — the
            // server's `-ss` can land late on the source audio
            // (device-measured +20.5 ms at a far seek), and a boundary
            // anchor would play that whole run's audio early by the gap.
            // The from-zero clamp hides the declared clock, so that run
            // keeps the boundary.
            let clamped = runStart90k == 0 && frames.first?.pts90k == TranscodedAudioRun.muxOffset90k
            let firstKept = clamped ? nil : frames.dropFirst(min(priming, frames.count)).first?.pts90k
            anchorTicks = TranscodedAudioRun.anchorTicks(
                firstKeptPTS90k: firstKept,
                runStartTicks90k: runStart90k,
                ticksPerFrame90k: ticksPerFrame90k,
                sampleRate: Int(rate),
            )
            let boundaryTicks = segmentStartTicks10M[index] * rate / 10_000_000
            if anchorTicks != boundaryTicks {
                Self.logger.info("[remux-audio] run at segment \(index): anchor snapped \(self.anchorTicks - boundaryTicks) ticks (\(rate) Hz) to the declared first frame")
            }
            Self.logger.info("[remux-audio] run started at segment \(index) (+\(self.segmentStartTicks10M[index] / 10_000_000)s), dropped \(priming) priming frames")
            nextExpectedPTS90k = (frames.first?.pts90k).map { $0 + Int64(frames.count) * ticksPerFrame90k }
        } else if let first = frames.first {
            // Continuing run: the declared clock should advance exactly one
            // frame per frame. Log drift past half a frame instead of
            // correcting, because the intrinsic grid — not the ms-quantized
            // declaration — is the hypothesis under test.
            if let expected = nextExpectedPTS90k, abs(first.pts90k - expected) > ticksPerFrame90k / 2 {
                Self.logger.warning("[remux-audio] segment \(index): declared pts deviates \(first.pts90k - expected) ticks (90 kHz) from the sample grid")
            }
            nextExpectedPTS90k = first.pts90k + Int64(frames.count) * ticksPerFrame90k
        }
        buffer.append(contentsOf: payloads)
        nextSegment += 1
    }

    // MARK: - Helpers

    private func segmentIndex(coveringTicks ticks: Int64, rate: Int64) -> Int {
        let target = ticks * 10_000_000 / rate
        // Last segment whose start is at or before the target.
        var index = 0
        for (i, start) in segmentStartTicks10M.enumerated() where start <= target {
            index = i
        }
        return index
    }

    private func trim(before index: Int64) {
        let cut = Int(min(max(index, Int64(bufferBase)), Int64(bufferBase + buffer.count)))
        guard cut > bufferBase else { return }
        buffer.removeFirst(cut - bufferBase)
        bufferBase = cut
    }

    private func parsePlaylist(_ playlist: String) throws {
        var starts: [Int64] = []
        var lengths: [Int64] = []
        var cursor: Int64 = 0
        for line in playlist.split(separator: "\n") {
            guard line.hasPrefix("#EXTINF:") else { continue }
            let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
            guard let seconds = Double(value), seconds > 0 else {
                throw TransportStreamAudioError.malformed("EXTINF \(value)")
            }
            let ticks = Int64((seconds * 10_000_000).rounded())
            starts.append(cursor)
            lengths.append(ticks)
            cursor += ticks
        }
        guard !starts.isEmpty else {
            throw TransportStreamAudioError.malformed("playlist without segments")
        }
        segmentStartTicks10M = starts
        segmentLengthTicks10M = lengths
        totalDurationTicks10M = cursor
    }

    private func ceilDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        value <= 0 ? 0 : (value + divisor - 1) / divisor
    }
}

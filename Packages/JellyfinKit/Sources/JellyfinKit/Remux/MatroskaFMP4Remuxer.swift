import Foundation

// The bridge from demuxed Matroska clusters to fMP4 segments (#176): track
// selection, sample timing, and the profile-7 Dolby Vision filter. One
// fragment per planned segment — a merged run of adjacent Cues (#99, see
// `HLSSegmentPlan`) — with every fragment boundary on a Cue keyframe, so
// seeking stays exact.
//
// Timing is the one genuinely subtle part. Matroska block timestamps are
// PRESENTATION times in storage (decode) order; fMP4 needs monotonic DECODE
// times plus per-sample composition offsets. Decode times are synthesized by
// sorting the fragment's presentation times ascending — valid because a
// frame cannot be presented before it is decoded, so the i-th decoded frame's
// presentation time is never below the i-th smallest — with every sample
// keeping its honest duration so consecutive fragments tile one continuous
// decode clock (see `videoFragment`, #99). The offsets are signalled via
// version-1 (signed) `trun`.

public struct MatroskaFMP4Remuxer: Sendable {
    public struct SelectedTracks: Sendable, Equatable {
        public let video: MatroskaTrack
        public let audio: MatroskaTrack?

        public init(video: MatroskaTrack, audio: MatroskaTrack?) {
            self.video = video
            self.audio = audio
        }
    }

    public enum RemuxError: Error, Equatable {
        /// The source's codecs cannot be carried into fMP4; the session must
        /// stay on the server path.
        case unsupportedVideoCodec(String)
        case unsupportedAudioCodec(String)
        case missingCodecPrivate
        /// Video sample whose NAL length prefixes do not parse.
        case malformedVideoSample
    }

    static let supportedVideoCodecIDs: Set<String> = ["V_MPEGH/ISO/HEVC", "V_MPEG4/ISO/AVC"]
    static let supportedAudioCodecIDs: Set<String> = ["A_AAC", "A_AC3", "A_EAC3", "A_FLAC"]

    public let index: MatroskaIndex
    public let tracks: SelectedTracks
    /// fMP4 timescale in ticks per second, derived from the Matroska
    /// timestamp scale (1ms ticks -> 1000). Sample times pass through 1:1.
    public let timescale: Int

    /// The carried tracks' IDs, video first — what a sidx must reference.
    public var trackIDs: [Int] {
        [tracks.video.number] + (tracks.audio.map { [$0.number] } ?? [])
    }

    private let videoContext: VideoContext
    private let audioDefaultDurationTicks: Int?

    private struct VideoContext: Sendable {
        let codec: FMP4Muxer.VideoCodec
        /// NAL length-prefix width from the configuration record — assuming 4
        /// was the spike's probe bug #1.
        let nalLengthSize: Int
        let filtersEnhancementLayer: Bool
        let defaultDurationTicks: Int?
    }

    // MARK: - Setup

    /// Pick the tracks a remux would carry: the first supported video track,
    /// and the first supported audio track (preferring ones flagged default).
    /// Returns `nil` when no supported video track exists. A source whose
    /// audio tracks are all unsupported (TrueHD/DTS-only) yields
    /// `audio == nil`; whether to proceed video-only or refuse is the
    /// caller's delivery-policy decision.
    public static func selectTracks(from index: MatroskaIndex) -> SelectedTracks? {
        let video = index.tracks.first { $0.type == .video && supportedVideoCodecIDs.contains($0.codecID) }
        guard let video else { return nil }
        let audioCandidates = index.tracks.filter { $0.type == .audio && supportedAudioCodecIDs.contains($0.codecID) }
        let audio = audioCandidates.first { $0.isDefault } ?? audioCandidates.first
        return SelectedTracks(video: video, audio: audio)
    }

    public init(index: MatroskaIndex, tracks: SelectedTracks) throws {
        self.index = index
        self.tracks = tracks
        timescale = Int(1_000_000_000 / max(index.timestampScaleNs, 1))

        guard let codecPrivate = tracks.video.codecPrivate, !codecPrivate.isEmpty else {
            throw RemuxError.missingCodecPrivate
        }
        let ticksPerNs = 1.0 / Double(max(index.timestampScaleNs, 1))
        func ticks(fromNs ns: UInt64?) -> Int? {
            ns.map { Int((Double($0) * ticksPerNs).rounded()) }
        }

        switch tracks.video.codecID {
        case "V_MPEGH/ISO/HEVC":
            // CodecPrivate IS the hvcC record (spike finding 1); byte 21's low
            // bits carry lengthSizeMinusOne.
            guard codecPrivate.count >= 23 else { throw RemuxError.missingCodecPrivate }
            let lengthSize = Int(codecPrivate[codecPrivate.startIndex + 21] & 0x03) + 1
            let sourceDV = tracks.video.dolbyVisionConfiguration
            let signalledDV = sourceDV?.signalledForAVFoundation()
            videoContext = VideoContext(
                codec: .hevc(hvcC: codecPrivate, dolbyVision: signalledDV),
                nalLengthSize: lengthSize,
                filtersEnhancementLayer: sourceDV?.requiresEnhancementLayerFilter ?? false,
                defaultDurationTicks: ticks(fromNs: tracks.video.defaultDurationNs),
            )
        case "V_MPEG4/ISO/AVC":
            guard codecPrivate.count >= 5 else { throw RemuxError.missingCodecPrivate }
            let lengthSize = Int(codecPrivate[codecPrivate.startIndex + 4] & 0x03) + 1
            videoContext = VideoContext(
                codec: .h264(avcC: codecPrivate),
                nalLengthSize: lengthSize,
                filtersEnhancementLayer: false,
                defaultDurationTicks: ticks(fromNs: tracks.video.defaultDurationNs),
            )
        default:
            throw RemuxError.unsupportedVideoCodec(tracks.video.codecID)
        }

        audioDefaultDurationTicks = ticks(fromNs: tracks.audio?.defaultDurationNs)
    }

    // MARK: - Initialization segment

    /// Build the init segment. AC-3/E-AC-3 configuration is parsed from the
    /// first audio frame, so the first cluster must be supplied.
    public func makeInitializationSegment(firstCluster: MatroskaCluster) throws -> Data {
        let video = FMP4Muxer.VideoTrack(
            trackID: tracks.video.number,
            codec: videoContext.codec,
            width: tracks.video.pixelWidth ?? 0,
            height: tracks.video.pixelHeight ?? 0,
        )
        var audio: FMP4Muxer.AudioTrack?
        if let audioTrack = tracks.audio {
            let firstFrame = firstCluster.frames.first { $0.trackNumber == audioTrack.number }?.data
            guard let configuration = AudioSampleEntryConfiguration.make(for: audioTrack, firstFrame: firstFrame) else {
                throw RemuxError.unsupportedAudioCodec(audioTrack.codecID)
            }
            audio = FMP4Muxer.AudioTrack(
                trackID: audioTrack.number,
                configuration: configuration,
                channelCount: audioTrack.channels ?? 2,
                sampleRate: Int(audioTrack.samplingFrequency ?? 48000),
            )
        }
        return FMP4Muxer.initializationSegment(
            video: video,
            audio: audio,
            timescale: timescale,
        )
    }

    // MARK: - Fragments

    /// Remux one planned span into one `moof`+`mdat`.
    ///
    /// `nextSpanHead` is the NEXT span's opening cluster
    /// (`MatroskaDemuxer.readFirstCluster`), `nil` for the final span. Video
    /// frames are re-partitioned at keyframes across that boundary — see
    /// `videoFragment` — so consecutive fragments tile one continuous decode
    /// clock (#99). Every sample carries its honest duration; nothing
    /// stretches to the next cue.
    public func makeFragment(
        sequence: Int,
        cluster: MatroskaCluster,
        nextSpanHead: MatroskaCluster?,
    ) throws -> Data {
        var fragments: [FMP4Muxer.TrackFragment] = []
        if let video = try videoFragment(cluster: cluster, nextSpanHead: nextSpanHead) {
            fragments.append(video)
        }
        if let audioTrack = tracks.audio,
           let audio = audioFragment(track: audioTrack, cluster: cluster)
        {
            fragments.append(audio)
        }
        return FMP4Muxer.mediaSegment(sequence: sequence, fragments: fragments)
    }

    private func videoFragment(cluster: MatroskaCluster, nextSpanHead: MatroskaCluster?) throws -> FMP4Muxer.TrackFragment? {
        // Re-partition video frames at keyframes, in decode (storage) order:
        // drop this span's frames BEFORE its first keyframe, and claim the
        // next span's frames before ITS first keyframe. A GOP that straddles
        // the span boundary stores its final P/B frames in the next span's
        // opening cluster — those frames decode before that span's cued
        // keyframe and present interleaved with this span's tail, so leaving
        // them where the cluster packing put them makes the two spans'
        // presentation windows overlap ~2–3 frames, and no per-span decode
        // timeline can tile. Partitioned at keyframes, each window is
        // decode-contiguous and the windows tile exactly. The rule is local
        // to each span, so out-of-order (seek) generation stays consistent;
        // the frames a fragment drops are exactly the ones a decoder joining
        // at its keyframe could not decode anyway.
        let own = cluster.frames.filter { $0.trackNumber == tracks.video.number }
        var frames = if let keyIndex = own.firstIndex(where: \.isKeyframe) {
            Array(own[keyIndex...])
        } else {
            own
        }
        // Where the NEXT fragment's timeline will start: the minimum
        // presentation time of the head's frames from its first keyframe on
        // (with open-GOP leading pictures that minimum sits BELOW the
        // keyframe — which is why the next keyframe's own timestamp is not
        // the bound). Bounds the last sample so the tile stays exact even on
        // variable frame durations, where a fallback guess would drift.
        var nextFragmentStartTicks: Int64?
        if let nextSpanHead {
            let head = nextSpanHead.frames.filter { $0.trackNumber == tracks.video.number }
            frames.append(contentsOf: head.prefix { !$0.isKeyframe })
            if let keyIndex = head.firstIndex(where: \.isKeyframe) {
                nextFragmentStartTicks = head[keyIndex...].map(\.timeTicks).min()
            }
        }
        guard !frames.isEmpty else { return nil }

        var payloads: [Data] = []
        payloads.reserveCapacity(frames.count)
        for frame in frames {
            if videoContext.filtersEnhancementLayer {
                guard let filtered = HEVCNALFilter.droppingEnhancementLayer(
                    from: frame.data,
                    lengthSize: videoContext.nalLengthSize,
                ) else { throw RemuxError.malformedVideoSample }
                payloads.append(filtered)
            } else {
                payloads.append(frame.data)
            }
        }

        // Decode times: the fragment's presentation times, sorted ascending.
        //
        // The LAST sample runs to the next fragment's actual start
        // (`nextFragmentStartTicks`) — one honest frame on constant-rate
        // video, the true gap on variable — and NEVER to the next segment's
        // cue time. The cue-time stretch was the other half of #99's broken
        // decode clock: with the keyframe re-partition above, the next
        // fragment's timeline starts below its cue whenever leading pictures
        // exist, so stretching to the cue claimed the boundary window twice,
        // stepping `tfdt` backwards ~2 frames at every boundary — measured
        // −83/−126/−167ms on this plan's own segments — which AVFoundation
        // renders as the periodic skip, with zero dropped frames.
        let presentationTimes = frames.map(\.timeTicks)
        let decodeTimes = presentationTimes.sorted()
        let fallbackDuration = videoContext.defaultDurationTicks
            ?? (decodeTimes.count > 1 ? Int(decodeTimes[1] - decodeTimes[0]) : 1)
        var samples: [FMP4Muxer.Sample] = []
        samples.reserveCapacity(frames.count)
        for (i, frame) in frames.enumerated() {
            let duration: Int = if i + 1 < decodeTimes.count {
                Int(decodeTimes[i + 1] - decodeTimes[i])
            } else if let next = nextFragmentStartTicks, next > decodeTimes[i] {
                Int(next - decodeTimes[i])
            } else {
                fallbackDuration
            }
            samples.append(FMP4Muxer.Sample(
                duration: max(duration, 0),
                size: payloads[i].count,
                isSync: frame.isKeyframe,
                compositionOffset: Int(frame.timeTicks - decodeTimes[i]),
            ))
        }

        var data = Data(capacity: payloads.reduce(0) { $0 + $1.count })
        for payload in payloads {
            data.append(payload)
        }
        return FMP4Muxer.TrackFragment(
            trackID: tracks.video.number,
            baseDecodeTime: decodeTimes[0],
            samples: samples,
            data: data,
            isVideo: true,
        )
    }

    private func audioFragment(track: MatroskaTrack, cluster: MatroskaCluster) -> FMP4Muxer.TrackFragment? {
        let frames = cluster.frames.filter { $0.trackNumber == track.number }
        guard !frames.isEmpty else { return nil }

        // Laced frames share their block's timestamp; spread each equal-time
        // run evenly across the gap to the next distinct timestamp.
        let times = frames.map(\.timeTicks)
        var durations = [Int](repeating: 0, count: frames.count)
        var runStart = 0
        var lastPerFrame = audioDefaultDurationTicks ?? 0
        while runStart < times.count {
            var runEnd = runStart
            while runEnd < times.count, times[runEnd] == times[runStart] {
                runEnd += 1
            }
            let count = runEnd - runStart
            if runEnd < times.count {
                let delta = Int(times[runEnd] - times[runStart])
                let perFrame = delta / count
                for i in runStart ..< runEnd {
                    durations[i] = perFrame
                }
                durations[runEnd - 1] += delta - perFrame * count
                if perFrame > 0 {
                    lastPerFrame = perFrame
                }
            } else {
                let perFrame = lastPerFrame > 0 ? lastPerFrame : 1
                for i in runStart ..< runEnd {
                    durations[i] = perFrame
                }
            }
            runStart = runEnd
        }

        let samples = zip(frames, durations).map { frame, duration in
            FMP4Muxer.Sample(duration: duration, size: frame.data.count, isSync: true)
        }
        var data = Data(capacity: frames.reduce(0) { $0 + $1.data.count })
        for frame in frames {
            data.append(frame.data)
        }
        return FMP4Muxer.TrackFragment(
            trackID: track.number,
            baseDecodeTime: times[0],
            samples: samples,
            data: data,
            isVideo: false,
        )
    }
}

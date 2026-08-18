import AVFoundation
import Foundation
import JellyfinKit
import OSLog
#if os(tvOS)
    import UIKit
#endif

/// The stream the delivery layer settled on: what the engine should load,
/// and the play method that is actually true of it. Delivery may correct
/// the method (the degraded interposer fallback does) — the corrected value
/// must flow back so start reports never lie about the session.
struct DeliveredStream {
    let url: URL
    let playMethod: PlayMethod
}

/// How a resolved stream reaches the engine (#85).
///
/// Sits between stream resolution (JellyfinKit's `resolveStream`) and the
/// engine's `load`: a delivery may pass the URL through untouched, or stand
/// up machinery of its own — today the loopback interposer, and this is the
/// seam where the in-app remux HLS path (#172/#176) plugs in as a
/// conformance rather than a branch in `PlaybackViewModel`.
@MainActor
protocol StreamDelivery: AnyObject {
    /// Prepare the stream and return what the engine should load. Never
    /// throws: every delivery must resolve to something playable or fall
    /// back to the origin URL it was given.
    func prepare() async -> DeliveredStream

    /// Release anything the delivery stood up. Idempotent.
    func stop()

    /// Called at most once when the delivery fails permanently mid-session
    /// — the stream it stood up can no longer serve, retries included, and
    /// only a rebuild that avoids this rung recovers. Deliveries that
    /// cannot fail this way never call it.
    var onPermanentFailure: (() -> Void)? { get set }
}

/// Everything a delivery needs to know about the session it serves.
struct DeliveryContext {
    let itemId: String
    let mediaSource: MediaSource?
    let playSessionId: String?
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let trickplayInfo: TrickplayInfo?
    let capabilities: PlaybackCapabilities
    /// A remux HLS session for this item already failed mid-file, so the
    /// rebuild must start from the copy variant instead of standing the
    /// remux up again to fail on the same cluster.
    var avoidInAppRemux = false
}

/// Picks the delivery for a resolved stream. The rule is the play method:
/// direct play takes the original file untouched; every HLS session runs
/// through the loopback interposer — except the one case server HLS
/// structurally cannot serve (#172): an HDR MKV on an SDR display gets an
/// app-remuxed, master-less HLS session instead.
@MainActor
enum StreamDeliverySelector {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    /// Whether the ATTACHED DISPLAY can take HDR — which is what the
    /// `-12927` variant gate follows, so it is what this gate must follow.
    ///
    /// Neither AVPlayer class property tracks it. Measured 2026-08-02 on the
    /// Apple TV 4K driving the 1080p SDR panel — the same rig where #146
    /// captured the variant gate refusing HDR variants — BOTH claim HDR:
    /// `eligibleForHDRPlayback=true` (device capability by its own doc
    /// wording) and `availableHDRModes=[.hdr10]` (despite "an appropriate
    /// HDR display is available"). The screen's EDR headroom is the signal
    /// that describes what the panel can actually render: 1.0 means SDR is
    /// the ceiling. visionOS keeps the eligibility property — its display is
    /// HDR and the UIScreen API is unavailable there.
    static var displaySupportsHDR: Bool {
        #if os(visionOS)
            AVPlayer.eligibleForHDRPlayback
        #else
            (activeScreen?.potentialEDRHeadroom ?? 1.0) > 1.0
        #endif
    }

    #if !os(visionOS)
        /// The attached display, found through the active scene — the
        /// non-deprecated route to what `UIScreen.main` answered; tvOS has
        /// exactly one. A missing scene reads as SDR, which routes an HDR
        /// source to the remux delivery, which plays on either panel.
        private static var activeScreen: UIScreen? {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen }
                .first
        }
    #endif

    static func delivery(
        for resolution: StreamResolution,
        context: DeliveryContext,
        client: any JellyfinClientProtocol,
        displaySupportsHDR: Bool = StreamDeliverySelector.displaySupportsHDR,
    ) -> any StreamDelivery {
        if resolution.playMethod == .directPlay {
            return DirectDelivery(resolution: resolution)
        }
        let remuxHLS = RemuxHLSDelivery.isEligible(context: context, displaySupportsHDR: displaySupportsHDR)
        // The inputs, not just the verdict: a wrong clause here routes the
        // session silently, which is invisible to every suite in the repo.
        // Both HDR signals are logged so a device run can arbitrate them.
        let source = context.mediaSource
        #if os(visionOS)
            let displaySignals = "n/a"
        #else
            let displaySignals = activeScreen.map {
                "edrPotential=\($0.potentialEDRHeadroom) edrCurrent=\($0.currentEDRHeadroom) gamut=\($0.traitCollection.displayGamut.rawValue)"
            } ?? "screen=nil"
        #endif
        logger.info("[delivery] \(remuxHLS ? "remux HLS" : "HLS interposer", privacy: .public) — displayHDR=\(displaySupportsHDR) eligibleForHDR=\(AVPlayer.eligibleForHDRPlayback) \(displaySignals, privacy: .public) container=\(source?.container ?? "nil", privacy: .public) range=\(source?.videoStream?.videoRange ?? "nil", privacy: .public) codec=\(source?.videoCodec ?? "nil", privacy: .public)")
        if remuxHLS {
            return RemuxHLSDelivery(resolution: resolution, context: context, client: client)
        }
        return InterposedHLSDelivery(resolution: resolution, context: context, client: client)
    }
}

// MARK: - Direct

/// Direct play: the engine loads the original file's URL, nothing between.
@MainActor
final class DirectDelivery: StreamDelivery {
    private let resolution: StreamResolution
    var onPermanentFailure: (() -> Void)?

    init(resolution: StreamResolution) {
        self.resolution = resolution
    }

    func prepare() async -> DeliveredStream {
        DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
    }

    func stop() {}
}

// MARK: - Interposed HLS

/// HLS through the loopback interposer: a local server rewrites the master
/// playlist to add the synthesized trickplay I-frame rendition and drop
/// subtitle renditions the server advertises but cannot serve as text.
@MainActor
final class InterposedHLSDelivery: StreamDelivery {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let resolution: StreamResolution
    private let context: DeliveryContext
    private let client: any JellyfinClientProtocol
    var onPermanentFailure: (() -> Void)?

    /// The loopback server interposing the master playlist; nil until
    /// `prepare` succeeds or when the listener could not start
    private var localServer: PlaybackLocalServer?

    init(
        resolution: StreamResolution,
        context: DeliveryContext,
        client: any JellyfinClientProtocol,
    ) {
        self.resolution = resolution
        self.context = context
        self.client = client
    }

    func prepare() async -> DeliveredStream {
        let itemId = context.itemId
        let sourceId = context.mediaSource?.id
        let client = client
        let info = context.trickplayInfo
        // Jellyfin advertises image (PGS) subtitle streams as renditions it
        // cannot serve as text; the proxy drops them so AVKit's picker only
        // offers subtitles that can actually render
        let unservable = Set(
            (context.mediaSource?.subtitleStreams ?? [])
                .filter { !$0.isTextSubtitleStream }
                .compactMap(\.displayTitle),
        )
        let server = PlaybackLocalServer(
            originalMasterURL: resolution.url,
            info: info,
            unservableSubtitleNames: unservable,
        ) { tileIndex in
            guard let info else { return nil }
            return client.trickplayTileURL(
                itemId: itemId,
                width: info.widthKey,
                tileIndex: tileIndex,
                mediaSourceId: sourceId,
            )
        }

        guard let interposedURL = await server.start() else {
            // A cancelled build is not a degraded one: its result is always
            // discarded at the caller's supersede guard, so spend nothing on
            // it — no re-resolve, no misleading "listener unavailable" log
            if Task.isCancelled {
                return DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
            }
            // Degraded path: nothing will strip the WebVTT timestamp map,
            // so re-resolve with the interposer assumption off — a
            // delivered text subtitle falls back to TS + H.264, where the
            // map's offset aligns and cues stay correctly timed (slower for
            // HEVC sources, but never silently 10s late)
            Self.logger.warning("[server] loopback listener unavailable; falling back to origin delivery")
            if let source = context.mediaSource,
               let fallback = try? client.resolveStream(
                   for: source,
                   parameters: StreamParameters(
                       itemId: itemId,
                       mediaSourceId: source.id,
                       playSessionId: context.playSessionId,
                       audioStreamIndex: context.audioStreamIndex,
                       subtitleStreamIndex: context.subtitleStreamIndex,
                   ),
                   capabilities: context.capabilities,
                   assumeInterposer: false,
               )
            {
                return DeliveredStream(url: fallback.url, playMethod: fallback.playMethod)
            }
            return DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
        }
        localServer = server
        return DeliveredStream(url: interposedURL, playMethod: resolution.playMethod)
    }

    func stop() {
        localServer?.stop()
        localServer = nil
    }
}

// MARK: - Remux HLS

/// The app-owned HLS delivery mode (#172): demux the original MKV over
/// ranged HTTP, remux to fMP4 segments in-app, and serve them behind a
/// master-less media playlist from loopback.
///
/// Selected only for the case server HLS structurally cannot serve: an HDR
/// source on an SDR display. AVFoundation's eligibility gate (#146) fires
/// at variant selection over declared master attributes — a master
/// declaring 4K PQ is refused (`-11868`, CoreMedia `-17223`) whoever wrote
/// it — and the server-side fallback is a software tone-map a decode-bound
/// host delivers at 0.88× realtime (a frozen player). A media playlist
/// with no master never reaches variant selection, so nothing can be ruled
/// ineligible, and the display pipeline tone-maps the segments on-device
/// (measured 2026-08-02: genuine 4K PQ segments reach `readyToPlay` and
/// buffer on the SDR-panel rig). A progressive fMP4 was tried first and is
/// a dead end — the file reader ignores `sidx` and linear-scans the file.
///
/// Everything here can fail somewhere real — the origin may ignore `Range`,
/// the file may have no Cues, the codecs may not be carriable (DTS-only
/// audio is the common case) — so failures descend a ladder:
///
/// 1. The in-app remux above.
/// 2. The SERVER's copy variant, master-less: re-resolve the session's HLS
///    URL, fetch the master, and hand the engine the media playlist of the
///    variant marked `AllowVideoStreamCopy=true`. Video is stream-copied
///    (9.89× realtime measured — no tone-map starvation), unsupported audio
///    is transcoded server-side, and with no master there is nothing for
///    the eligibility gate to rule ineligible. Measured 2026-08-02 on the
///    SDR-panel rig with a 4K DV profile 7 + DTS-HD MA source: readyToPlay
///    in 4s, rate 1.0 sustained, buffer 100s ahead.
/// 3. The interposed HLS delivery this session would otherwise have used —
///    degraded (the tone-map), never dead.
///
/// Known gaps, accepted for modes 1 and 2: no subtitle renditions and no
/// trickplay (#176 step 3 territory; both live in the master this delivery
/// exists to avoid). Mode 1 only ever plays the source's DEFAULT audio
/// track — carried from the file when the codec allows, muxed in from a
/// server-side audio-only transcode when it is DTS/TrueHD (#249,
/// `TranscodedAudioSession`) — so a session committed to any other track
/// skips straight to mode 2, which honors the selection
/// (`rung1DeclineReason`).
@MainActor
final class RemuxHLSDelivery: StreamDelivery {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let resolution: StreamResolution
    private let context: DeliveryContext
    private let client: any JellyfinClientProtocol
    var onPermanentFailure: (() -> Void)?

    private var server: RemuxHLSServer?
    /// The HLS delivery every failure falls back to; also what `stop()`
    /// must tear down when the fallback was taken.
    private var fallback: InterposedHLSDelivery?

    init(
        resolution: StreamResolution,
        context: DeliveryContext,
        client: any JellyfinClientProtocol,
    ) {
        self.resolution = resolution
        self.context = context
        self.client = client
    }

    /// Whether this session is the HDR-on-SDR MKV case. Everything else
    /// keeps its current path untouched.
    static func isEligible(context: DeliveryContext, displaySupportsHDR: Bool) -> Bool {
        guard !displaySupportsHDR,
              let source = context.mediaSource,
              let container = source.container?.lowercased(),
              container.split(separator: ",").contains(where: { $0 == "mkv" || $0 == "matroska" }),
              source.videoStream?.videoRange != nil,
              let codec = source.videoCodec?.lowercased(),
              codec == "hevc" || codec == "h264"
        else { return false }
        return true
    }

    func prepare() async -> DeliveredStream {
        if let reason = Self.rung1DeclineReason(context: context) {
            Self.logger.info("[remux-hls] skipping the in-app remux (\(reason, privacy: .public)); trying the master-less copy variant")
            return await descendLadder()
        }
        do {
            return try await prepareRemuxHLS()
        } catch {
            guard !Task.isCancelled else {
                return DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
            }
            Self.logger.warning("[remux-hls] unavailable (\(PlaybackLog.error(error), privacy: .public)); trying the master-less copy variant")
            return await descendLadder()
        }
    }

    /// Audio codecs (Jellyfin stream-info spelling) the remux can carry —
    /// `MatroskaFMP4Remuxer.supportedAudioCodecIDs` seen from the server's
    /// metadata instead of the Matroska track header.
    static let remuxCarriableAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "flac"]

    /// Why rung 1 must not even be attempted for this session, or nil to
    /// attempt it.
    ///
    /// The audio clause closes a dead control: rung 1 plays the source's
    /// default track — carried from the file, or server-transcoded when the
    /// file's default is DTS/TrueHD (#249) — and ignores the session's
    /// committed audio index. An audio selection used to rebuild straight
    /// back into rung 1, which re-picked the same default: a spinner, the
    /// same track playing, and the menu's checkmark on a track that never
    /// played. Descending to the copy variant instead honors the selection
    /// server-side (the video stays stream-copied).
    static func rung1DeclineReason(context: DeliveryContext) -> String? {
        if context.avoidInAppRemux {
            return "a remux session already failed mid-file"
        }
        guard let source = context.mediaSource else { return nil }
        if let requested = context.audioStreamIndex, requested != source.defaultAudioStreamIndex {
            return "session audio stream \(requested) is not the default"
        }
        return nil
    }

    /// Rungs 2 and 3, in order: the copy variant, then the interposer.
    private func descendLadder() async -> DeliveredStream {
        if let copyVariant = await prepareCopyVariant() {
            return copyVariant
        }
        guard !Task.isCancelled else {
            return DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
        }
        Self.logger.warning("[copy-variant] unavailable; falling back to interposed HLS delivery")
        let fallback = InterposedHLSDelivery(resolution: resolution, context: context, client: client)
        self.fallback = fallback
        return await fallback.prepare()
    }

    /// Ladder rung 2: the server's stream-copy variant served master-less.
    /// Returns nil on any miss so the caller descends to the interposer.
    private func prepareCopyVariant() async -> DeliveredStream? {
        guard let source = context.mediaSource else { return nil }
        // Re-resolve rather than reuse `resolution.url`: the engine's
        // declared ranges exclude DOVIWithEL (profile 7), so the session's
        // own master has no copy variant for those sources. Widening is
        // safe here and only here — the base layer decodes as PQ and the
        // display tone-maps on-device. Same PlaySessionId, so the app's
        // existing stop reporting still kills the server transcode.
        let resolved: StreamResolution
        do {
            resolved = try client.resolveStream(
                for: source,
                parameters: StreamParameters(
                    itemId: context.itemId,
                    mediaSourceId: source.id,
                    playSessionId: context.playSessionId,
                    audioStreamIndex: context.audioStreamIndex,
                    subtitleStreamIndex: context.subtitleStreamIndex,
                ),
                capabilities: context.capabilities.includingEnhancementLayerRange(),
                assumeInterposer: false,
            )
        } catch {
            Self.logger.warning("[copy-variant] re-resolve failed: \(PlaybackLog.error(error), privacy: .public)")
            return nil
        }
        guard resolved.playMethod != .directPlay else { return nil }

        // The m3u8 endpoint only OFFERS a copy variant when the request
        // itself declares `AllowVideoStreamCopy=true` — measured 2026-08-02
        // against the rig: the app's exact param set gains the copy variant
        // with the flag and loses it without, independent of every other
        // parameter. PlaybackInfo-issued TranscodingUrls carry the flag;
        // this hand-built URL must too. The server echoes it into the
        // variant URI, so the media playlist inherits it.
        guard var components = URLComponents(url: resolved.url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "AllowVideoStreamCopy", value: "true")]
        guard let masterURL = components.url else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: masterURL),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            Self.logger.warning("[copy-variant] master fetch failed")
            return nil
        }
        let master = String(decoding: data, as: UTF8.self)
        guard let uri = HLSMasterCopyVariant.uri(inMaster: master) else {
            Self.logger.warning("[copy-variant] master offers no AllowVideoStreamCopy=true variant")
            return nil
        }
        guard let mediaURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL else {
            Self.logger.warning("[copy-variant] variant URI did not resolve against the master URL")
            return nil
        }
        Self.logger.info("[copy-variant] session up: serving the copy variant's media playlist master-less")
        return DeliveredStream(url: mediaURL, playMethod: resolved.playMethod)
    }

    private func prepareRemuxHLS() async throws -> DeliveredStream {
        guard let source = context.mediaSource else {
            throw MatroskaError.malformed("no media source")
        }
        let staticURL = try client.staticStreamURL(for: source, parameters: StreamParameters(
            itemId: context.itemId,
            mediaSourceId: source.id,
            playSessionId: context.playSessionId,
            audioStreamIndex: context.audioStreamIndex,
            subtitleStreamIndex: context.subtitleStreamIndex,
        ))

        let byteSource = try await RangedHTTPByteSource.probe(url: staticURL)
        let demuxer = MatroskaDemuxer(source: byteSource)
        let index = try await demuxer.loadIndex()
        guard var tracks = MatroskaFMP4Remuxer.selectTracks(from: index) else {
            throw MatroskaFMP4Remuxer.RemuxError.unsupportedVideoCodec(
                index.tracks.first { $0.type == .video }?.codecID ?? "none",
            )
        }
        // The default track is what rung 1 plays. When the file's default
        // is one the remux can neither carry nor AVFoundation decode
        // (DTS/TrueHD), the session takes the external-audio path (#249):
        // video remuxed from the file, the default track server-transcoded
        // to AAC and muxed in — substituting a different carriable track
        // would be the checkmark lie `rung1DeclineReason` explains, and
        // declining outright parks the session on the copy variant's
        // frameskip (#99). A source with no audio at all still declines:
        // there is nothing to transcode.
        guard source.defaultAudioStreamIndex != nil || tracks.audio != nil else {
            throw MatroskaFMP4Remuxer.RemuxError.unsupportedAudioCodec("none")
        }
        let defaultCodec = source.audioStreams
            .first { $0.index == source.defaultAudioStreamIndex }?.codec?.lowercased()
        let needsServerAudio = tracks.audio == nil
            || !Self.remuxCarriableAudioCodecs.contains(defaultCodec ?? "")
        if needsServerAudio {
            tracks = tracks.droppingAudio()
        }
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)

        let plan = HLSSegmentPlan(index: index, timescale: remuxer.timescale)
        guard !plan.segments.isEmpty else {
            throw MatroskaError.malformed("empty segment plan")
        }

        var externalAudio: RemuxHLSServer.ExternalAudio?
        let initSegment: Data
        if needsServerAudio {
            // Stand the audio transcode up first: its first segment carries
            // the stream parameters the init segment declares, and a session
            // whose audio endpoint fails should descend the ladder before
            // anything is served.
            let audioSession = try TranscodedAudioSession(stream: client.audioHLSStream(
                parameters: StreamParameters(
                    itemId: context.itemId,
                    mediaSourceId: source.id,
                    playSessionId: context.playSessionId,
                ),
                audioStreamIndex: source.defaultAudioStreamIndex,
            ))
            let info = try await audioSession.start()
            // Any unused fMP4 track ID works; past the file's own numbers
            // keeps the mapping legible in diagnostics.
            let trackID = (index.tracks.map(\.number).max() ?? 0) + 1
            externalAudio = RemuxHLSServer.ExternalAudio(session: audioSession, trackID: trackID)
            initSegment = try remuxer.makeExternalAudioInitializationSegment(
                audio: FMP4Muxer.AudioTrack(
                    trackID: trackID,
                    configuration: .aac(audioSpecificConfig: info.audioSpecificConfig),
                    channelCount: info.channelCount,
                    sampleRate: info.sampleRate,
                ),
                audioTimescale: info.sampleRate,
            )
        } else {
            // The init segment consumes only the first audio frame
            // (AC-3/E-AC-3 configuration), so read the raw first cue-to-cue
            // span: the merged first segment (#99) can be several times
            // larger, every byte of it on the critical path to first frame —
            // and its bytes would be fetched again for seg0 anyway.
            let firstEnd = index.cues.count > 1 ? index.cues[1].clusterOffset : index.segmentDataEnd
            let firstSpan = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: firstEnd)
            initSegment = try remuxer.makeInitializationSegment(firstCluster: firstSpan)
        }

        let server = RemuxHLSServer(
            demuxer: demuxer,
            remuxer: remuxer,
            plan: plan,
            initSegment: initSegment,
            externalAudio: externalAudio,
        )
        // A deterministic mid-file production failure (the file, not the
        // network) can never heal on retry — surface it so the session
        // rebuilds on the next rung instead of 500ing the same segment
        // forever (#176's failure posture).
        server.onUnrecoverableSegmentFailure = { [weak self] in
            Task { @MainActor in
                self?.onPermanentFailure?()
            }
        }
        guard let url = await server.start() else {
            throw MatroskaError.malformed("loopback listener unavailable")
        }
        self.server = server
        Self.logger.info("[remux-hls] session up: \(plan.segments.count) segments, video track \(tracks.video.number), audio \(tracks.audio?.codecID ?? (externalAudio != nil ? "server transcode of \(defaultCodec ?? "?")" : "none"), privacy: .public)")
        // directStream is the honest method: streams are copied, container
        // owned by the app, no server encode anywhere in the session.
        return DeliveredStream(url: url, playMethod: .directStream)
    }

    func stop() {
        server?.stop()
        server = nil
        fallback?.stop()
        fallback = nil
    }
}

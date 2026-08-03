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
/// the file may have no Cues, the codecs may not be carriable — so every
/// failure falls back to the interposed HLS delivery this session would
/// otherwise have used. That path is degraded (the tone-map), never dead.
///
/// Known gaps, accepted for this mode: no subtitle renditions and no
/// trickplay (#176 step 3 territory), and the embedded default audio
/// selection policy of the remuxer rather than the session's chosen track.
@MainActor
final class RemuxHLSDelivery: StreamDelivery {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let resolution: StreamResolution
    private let context: DeliveryContext
    private let client: any JellyfinClientProtocol

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
        do {
            return try await prepareRemuxHLS()
        } catch {
            guard !Task.isCancelled else {
                return DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
            }
            Self.logger.warning("[remux-hls] unavailable (\(error, privacy: .public)); falling back to interposed HLS delivery")
            let fallback = InterposedHLSDelivery(resolution: resolution, context: context, client: client)
            self.fallback = fallback
            return await fallback.prepare()
        }
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
        // Option (a) from #176: a source whose audio is all TrueHD/DTS has
        // no carriable track; declining to the server path is the only
        // honest move (a silent film would play smoothly and wrongly).
        guard let tracks = MatroskaFMP4Remuxer.selectTracks(from: index), tracks.audio != nil else {
            throw MatroskaFMP4Remuxer.RemuxError.unsupportedAudioCodec(
                index.tracks.first { $0.type == .audio }?.codecID ?? "none",
            )
        }
        let remuxer = try MatroskaFMP4Remuxer(index: index, tracks: tracks)

        let firstEnd = index.cues.count > 1 ? index.cues[1].clusterOffset : index.segmentDataEnd
        let firstSpan = try await demuxer.readClusters(from: index.cues[0].clusterOffset, to: firstEnd)
        let initSegment = try remuxer.makeInitializationSegment(firstCluster: firstSpan)
        let plan = HLSSegmentPlan(index: index, timescale: remuxer.timescale)

        let server = RemuxHLSServer(demuxer: demuxer, remuxer: remuxer, plan: plan, initSegment: initSegment)
        guard let url = await server.start() else {
            throw MatroskaError.malformed("loopback listener unavailable")
        }
        self.server = server
        Self.logger.info("[remux-hls] session up: \(plan.segments.count) segments, video track \(tracks.video.number), audio \(tracks.audio?.codecID ?? "none", privacy: .public)")
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

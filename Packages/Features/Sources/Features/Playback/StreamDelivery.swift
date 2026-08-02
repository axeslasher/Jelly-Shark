import AVFoundation
import Foundation
import JellyfinKit
import OSLog

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
/// seam where a future in-app remux (#176) or progressive path (#172) plugs
/// in as a new conformance rather than a branch in `PlaybackViewModel`.
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
/// through the loopback interposer — except the one case HLS structurally
/// cannot serve (#172): an HDR MKV on an SDR display goes progressive.
@MainActor
enum StreamDeliverySelector {
    static func delivery(
        for resolution: StreamResolution,
        context: DeliveryContext,
        client: any JellyfinClientProtocol,
        displaySupportsHDR: Bool = AVPlayer.eligibleForHDRPlayback,
    ) -> any StreamDelivery {
        if resolution.playMethod == .directPlay {
            return DirectDelivery(resolution: resolution)
        }
        if ProgressiveRemuxDelivery.isEligible(context: context, displaySupportsHDR: displaySupportsHDR) {
            return ProgressiveRemuxDelivery(resolution: resolution, context: context, client: client)
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

// MARK: - Progressive remux

/// The non-HLS delivery mode (#172): demux the original MKV over ranged
/// HTTP, remux to fMP4 in-app, and serve it progressively from loopback.
///
/// Selected only for the case HLS structurally cannot serve: an HDR source
/// on an SDR display. AVFoundation's eligibility gate (`-12927`, #146)
/// rules HDR variants out of any HLS master — whoever wrote it — and the
/// server-side fallback is a software tone-map a decode-bound host delivers
/// at 0.88× realtime (a frozen player). A progressive asset has no variants
/// to be ruled ineligible; the display pipeline tone-maps on-device, which
/// the same hardware demonstrably does well (the #172 premise test).
///
/// Everything here can fail somewhere real — the origin may ignore `Range`,
/// the file may have no Cues, the codecs may not be carriable — so every
/// failure falls back to the interposed HLS delivery this session would
/// otherwise have used. That path is degraded (the tone-map), never dead.
///
/// Known gaps, accepted for this mode: no subtitle renditions and no
/// trickplay (both are HLS constructs, #176 step 3 territory), and the
/// embedded default audio selection policy of the remuxer rather than the
/// session's chosen track.
@MainActor
final class ProgressiveRemuxDelivery: StreamDelivery {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let resolution: StreamResolution
    private let context: DeliveryContext
    private let client: any JellyfinClientProtocol

    private var server: ProgressiveRemuxServer?
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
            return try await prepareProgressive()
        } catch {
            guard !Task.isCancelled else {
                return DeliveredStream(url: resolution.url, playMethod: resolution.playMethod)
            }
            Self.logger.warning("[progressive] unavailable (\(error, privacy: .public)); falling back to HLS delivery")
            let fallback = InterposedHLSDelivery(resolution: resolution, context: context, client: client)
            self.fallback = fallback
            return await fallback.prepare()
        }
    }

    private func prepareProgressive() async throws -> DeliveredStream {
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
        let layout = ProgressiveMP4Layout(index: index, initSegment: initSegment, timescale: remuxer.timescale)

        let server = ProgressiveRemuxServer(demuxer: demuxer, remuxer: remuxer, layout: layout)
        guard let url = await server.start() else {
            throw MatroskaError.malformed("loopback listener unavailable")
        }
        self.server = server
        Self.logger.info("[progressive] session up: \(layout.slots.count) fragments, video track \(tracks.video.number), audio \(tracks.audio?.codecID ?? "none", privacy: .public)")
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

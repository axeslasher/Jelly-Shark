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
}

/// Picks the delivery for a resolved stream. The rule is the play method:
/// direct play takes the original file untouched; every HLS session runs
/// through the loopback interposer.
@MainActor
enum StreamDeliverySelector {
    static func delivery(
        for resolution: StreamResolution,
        context: DeliveryContext,
        client: any JellyfinClientProtocol,
    ) -> any StreamDelivery {
        resolution.playMethod == .directPlay
            ? DirectDelivery(resolution: resolution)
            : InterposedHLSDelivery(resolution: resolution, context: context, client: client)
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

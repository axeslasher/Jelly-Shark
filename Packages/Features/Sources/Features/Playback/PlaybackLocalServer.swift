import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import Network
import OSLog
import UniformTypeIdentifiers

/// A loopback HTTP server that interposes on the HLS master playlist for
/// two jobs AVFoundation cannot do against Jellyfin directly: native scrub
/// thumbnails and correctly-timed text subtitles on fMP4.
///
/// **Trickplay.** tvOS renders seek previews only from HLS I-frame
/// renditions, which Jellyfin's HLS does not provide (its trickplay is JPEG
/// tile sheets behind a Roku-style tag AVFoundation ignores). A
/// custom-scheme `AVAssetResourceLoader` cannot bridge the gap either:
/// AVFoundation's preview pipeline probes a loader-served rendition once
/// and then silently abandons it — I-frame media must be reachable over
/// real HTTP.
///
/// **Subtitles.** Jellyfin stamps `X-TIMESTAMP-MAP=MPEGTS:900000` onto its
/// WebVTT via an `AddVttTimeMap=true` parameter it puts on every segment
/// URI in the subtitle media playlist. That map aligns against TS video
/// segments; on fMP4 every cue lands 10s late. So the subtitle *playlist*
/// is proxied (the VTT bodies still stream straight from Jellyfin) and the
/// map is stripped only on the fMP4/HEVC path (`videoSegmentsAreFMP4`);
/// on the TS/H.264 path it is kept so cues stay aligned (see
/// `SubtitleHLSPlaylist` and issue #90).
///
/// Routes:
/// - `/master.m3u8`: fetches the real master from Jellyfin, absolutizes its
///   URIs, redirects subtitle renditions to `/subs/{n}.m3u8`, and — when
///   trickplay data exists — appends an `mjpg` I-frame rendition
///   (`TrickplayHLSPlaylist`); video/audio playlists keep streaming
///   directly from Jellyfin
/// - `/subs/{n}.m3u8`: fetches the origin subtitle playlist and rewrites
///   its segment URIs (`SubtitleHLSPlaylist`)
/// - `/iframe.m3u8`, `/init.mp4`: generated locally from the trickplay
///   manifest (`TrickplayIFrameMuxer`)
/// - `/seg{n}.m4s`: fetches the tile sheet covering thumbnail *n* (cached
///   via the shared `URLCache`), crops the cell, and wraps the JPEG in an
///   fMP4 fragment
///
/// The listener binds an ephemeral port on the loopback interface only.
/// Failures are tiered by what they would silently break: a failed
/// thumbnail segment costs one preview frame; a master whose rewrite is
/// refused (not a master playlist — it carries no subtitle renditions)
/// 302s to the origin so playback survives; but a failed origin fetch of
/// the master or a subtitle playlist answers 502, because the silent
/// alternative on the fMP4/HEVC path is subtitles rendered 10 seconds late
/// (the timestamp map is stripped only there; on TS a fallback would time
/// correctly, but failing loudly stays uniform across both paths).
final class PlaybackLocalServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let originalMasterURL: URL
    private let info: TrickplayInfo?

    /// Rendition NAMEs the master rewrite removes: Jellyfin advertises
    /// image (PGS) subtitle streams as renditions it cannot serve as text,
    /// and their NAME mirrors the stream's DisplayTitle
    private let unservableSubtitleNames: Set<String>

    private let tileURL: @Sendable (Int) -> URL?

    /// Tile fetches ride the shared URLCache; Jellyfin serves tiles without
    /// Cache-Control headers, so heuristic freshness is near zero and cached
    /// data must be preferred explicitly
    private let session: URLSession

    private let http = LoopbackHTTPListener(
        queueLabel: "com.justinlascelle.jellyshark.playback-server",
        logPrefix: "[server]",
    )
    private var queue: DispatchQueue {
        http.queue
    }

    /// Origin URLs of the subtitle renditions the served master redirected
    /// to `/subs/{n}.m3u8`, index-aligned; refreshed on every master serve
    private var subtitleOriginURLs: [URL] = []

    /// The last decoded tile sheet, so consecutive segments re-crop without
    /// re-decoding (one sheet covers columns × rows thumbnails)
    private var cachedSheet: (tileIndex: Int, image: CGImage)?

    /// - Parameters:
    ///   - originalMasterURL: The real HLS master URL resolved for playback
    ///   - info: The trickplay resolution to synthesize the I-frame
    ///     rendition from; nil serves subtitles only, no seek previews
    ///   - tileURL: Maps a tile-sheet index to its authenticated URL
    ///     (`JellyfinClientProtocol.trickplayTileURL`)
    ///   - protocolClasses: Test seam — `URLProtocol` stubs standing in for
    ///     the Jellyfin origin
    init(
        originalMasterURL: URL,
        info: TrickplayInfo?,
        unservableSubtitleNames: Set<String> = [],
        tileURL: @escaping @Sendable (Int) -> URL?,
        protocolClasses: [AnyClass]? = nil,
    ) {
        self.originalMasterURL = originalMasterURL
        self.info = info
        self.unservableSubtitleNames = unservableSubtitleNames
        self.tileURL = tileURL

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = .shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration)

        http.route = { [weak self] target, connection in
            guard let self else { return }
            // A head that is not a GET draws a dropped connection here (the
            // remux server answers 404 instead; this server predates it).
            guard let target else {
                connection.cancel()
                return
            }
            Task { await self.route(path: target, on: connection) }
        }
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start listening on an ephemeral loopback port
    /// - Returns: The interposed master playlist URL, or nil if the listener
    ///   could not start (callers fall back to the original URL) or the
    ///   calling task was cancelled (callers must unwind, not fall back)
    func start() async -> URL? {
        guard let port = await http.start() else { return nil }
        let trickplay = info.map { "width=\($0.widthKey), thumbnails=\($0.thumbnailCount)" } ?? "none"
        Self.logger.info("[server] listening on 127.0.0.1:\(port) (trickplay: \(trickplay, privacy: .public))")
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8")
    }

    func stop() {
        http.stop()
    }

    // MARK: - Routing

    private func route(path: String, on connection: NWConnection) async {
        Self.logger.debug("[server] GET \(path, privacy: .public)")
        switch path {
        case "/master.m3u8":
            await serveMaster(on: connection)
        case "/iframe.m3u8":
            guard let info else {
                http.send(status: "404 Not Found", on: connection)
                return
            }
            http.send(body: Data(iframePlaylist(info: info).utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
        case "/init.mp4":
            guard let info else {
                http.send(status: "404 Not Found", on: connection)
                return
            }
            let segment = TrickplayIFrameMuxer.initializationSegment(
                thumbnailWidth: info.thumbnailWidth,
                thumbnailHeight: info.thumbnailHeight,
                durationMilliseconds: info.thumbnailCount * info.intervalMilliseconds,
            )
            http.send(body: segment, contentType: "video/mp4", on: connection)
        default:
            if let index = subtitleIndex(fromPath: path) {
                await serveSubtitlePlaylist(index: index, on: connection)
            } else if let info, let index = segmentIndex(fromPath: path) {
                await serveSegment(thumbnailIndex: index, info: info, on: connection)
            } else {
                http.send(status: "404 Not Found", on: connection)
            }
        }
    }

    private func serveMaster(on connection: NWConnection) async {
        let data: Data
        do {
            var request = URLRequest(url: originalMasterURL)
            // The master reflects live stream parameters; never reuse a
            // stale copy from the artwork cache
            request.cachePolicy = .reloadIgnoringLocalCacheData
            (data, _) = try await session.data(for: request)
        } catch {
            // The origin is unreachable from the proxy. A redirect might
            // keep playback alive, but subtitles ride through this server
            // now, and a silent bounce to the origin would restore the 10s
            // timestamp offset — fail loudly instead.
            Self.logger.warning("[server] master fetch failed: \(error, privacy: .public)")
            http.send(status: "502 Bad Gateway", on: connection)
            return
        }

        guard let text = String(data: data, encoding: .utf8),
              let rewrite = TrickplayHLSPlaylist.rewriteMaster(
                  text,
                  originalURL: originalMasterURL,
                  iframePlaylistURI: "/iframe.m3u8",
                  info: info,
                  localSubtitleURI: { "/subs/\($0).m3u8" },
                  dropSubtitleNames: unservableSubtitleNames,
              )
        else {
            // A media playlist where a master was expected is a
            // server-shape regression (this input used to crash
            // MediaToolbox). It cannot be interposed on — but it also
            // carries no subtitle renditions, so bouncing the player to
            // the origin is safe: playback survives, thumbnails are given
            // up, and no mistimed subtitle can result.
            Self.logger.warning("[server] origin response is not a master playlist (no #EXT-X-STREAM-INF); redirecting to origin")
            http.send(status: "302 Found", headers: ["Location": originalMasterURL.absoluteString], on: connection)
            return
        }

        queue.sync { subtitleOriginURLs = rewrite.subtitleOriginURLs }
        http.send(body: Data(rewrite.playlist.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
    }

    private func iframePlaylist(info: TrickplayInfo) -> String {
        TrickplayHLSPlaylist.iframePlaylist(
            info: info,
            initializationURI: "/init.mp4",
        ) { "/seg\($0).m4s" }
    }

    // MARK: - Subtitles

    private func subtitleIndex(fromPath path: String) -> Int? {
        guard path.hasPrefix("/subs/"), path.hasSuffix(".m3u8") else {
            return nil
        }
        return Int(path.dropFirst(6).dropLast(5))
    }

    private func serveSubtitlePlaylist(index: Int, on connection: NWConnection) async {
        let origin = queue.sync {
            subtitleOriginURLs.indices.contains(index) ? subtitleOriginURLs[index] : nil
        }
        guard let origin else {
            Self.logger.warning("[server] no subtitle origin recorded for /subs/\(index)")
            http.send(status: "404 Not Found", on: connection)
            return
        }

        do {
            var request = URLRequest(url: origin)
            // Session-scoped like the master; never reuse a stale copy
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300 ~= http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let rewritten = SubtitleHLSPlaylist.rewrite(
                text,
                originalURL: origin,
                stripTimestampMap: videoSegmentsAreFMP4,
            )
            http.send(body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
        } catch {
            // Failing loudly drops cues on screen; a silent fallback to
            // the origin playlist would render them 10 seconds late
            Self.logger.warning("[server] subtitle playlist \(index) failed: \(error, privacy: .public)")
            http.send(status: "502 Bad Gateway", on: connection)
        }
    }

    /// Whether the video segments are fMP4 (the HEVC path, `SegmentContainer=mp4`).
    /// Only then does Jellyfin's WebVTT `X-TIMESTAMP-MAP` need stripping; on TS
    /// (the H.264 path) the map aligns cues correctly and is kept. Derived from
    /// the resolved master URL the session was built with.
    private var videoSegmentsAreFMP4: Bool {
        URLComponents(url: originalMasterURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.caseInsensitiveCompare("SegmentContainer") == .orderedSame }?
            .value?.caseInsensitiveCompare("mp4") == .orderedSame
    }

    // MARK: - Segments

    private func segmentIndex(fromPath path: String) -> Int? {
        guard path.hasPrefix("/seg"), path.hasSuffix(".m4s") else {
            return nil
        }
        return Int(path.dropFirst(4).dropLast(4))
    }

    private func serveSegment(thumbnailIndex: Int, info: TrickplayInfo, on connection: NWConnection) async {
        let location = TrickplayResolver.location(ofThumbnail: thumbnailIndex, info: info)
        do {
            let sheet = try await tileSheet(at: location.tileIndex)
            guard let thumbnail = sheet.cropping(to: location.cropRect),
                  let jpeg = Self.encodeJPEG(thumbnail)
            else {
                throw URLError(.cannotDecodeContentData)
            }

            let segment = TrickplayIFrameMuxer.mediaSegment(
                index: thumbnailIndex,
                durationMilliseconds: info.intervalMilliseconds,
                jpegData: jpeg,
            )
            http.send(body: segment, contentType: "video/mp4", on: connection)
        } catch {
            // Costs one preview frame; playback is unaffected
            Self.logger.debug("[server] segment \(thumbnailIndex) failed: \(error, privacy: .public)")
            http.send(status: "404 Not Found", on: connection)
        }
    }

    private func tileSheet(at tileIndex: Int) async throws -> CGImage {
        let cached = queue.sync { cachedSheet }
        if let cached, cached.tileIndex == tileIndex {
            return cached.image
        }

        guard let url = tileURL(tileIndex) else {
            throw URLError(.userAuthenticationRequired)
        }
        let (data, _) = try await session.data(from: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw URLError(.cannotDecodeContentData)
        }

        queue.sync { cachedSheet = (tileIndex, image) }
        return image
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary,
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}

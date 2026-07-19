import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import Network
import OSLog
import UniformTypeIdentifiers

/// A loopback HTTP server that gives the system player native scrub
/// thumbnails by interposing the HLS master playlist
///
/// tvOS renders seek previews only from HLS I-frame renditions, which
/// Jellyfin's HLS does not provide (its trickplay is JPEG tile sheets behind
/// a Roku-style tag AVFoundation ignores). A custom-scheme
/// `AVAssetResourceLoader` cannot bridge the gap either: AVFoundation's
/// preview pipeline probes a loader-served rendition once and then silently
/// abandons it — I-frame media must be reachable over real HTTP. So playback
/// points at this server instead:
///
/// - `/master.m3u8`: fetches the real master from Jellyfin, absolutizes its
///   URIs, and appends an `mjpg` I-frame rendition (`TrickplayHLSPlaylist`);
///   video/audio/subtitle playlists keep streaming directly from Jellyfin
/// - `/iframe.m3u8`, `/init.mp4`: generated locally from the trickplay
///   manifest (`TrickplayIFrameMuxer`)
/// - `/seg{n}.m4s`: fetches the tile sheet covering thumbnail *n* (cached
///   via the shared `URLCache`), crops the cell, and wraps the JPEG in an
///   fMP4 fragment
///
/// The listener binds an ephemeral port on the loopback interface only.
/// Failures degrade silently: if the server cannot start, playback uses the
/// original URL; if the master fetch fails mid-session, the player is
/// redirected to the origin; a failed segment costs one preview frame.
final class TrickplayLocalServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Trickplay")

    private let originalMasterURL: URL
    private let info: TrickplayInfo
    private let tileURL: @Sendable (Int) -> URL?

    /// Tile fetches ride the shared URLCache; Jellyfin serves tiles without
    /// Cache-Control headers, so heuristic freshness is near zero and cached
    /// data must be preferred explicitly
    private let session: URLSession

    private let queue = DispatchQueue(label: "com.justinlascelle.jellyshark.trickplay-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// The last decoded tile sheet, so consecutive segments re-crop without
    /// re-decoding (one sheet covers columns × rows thumbnails)
    private var cachedSheet: (tileIndex: Int, image: CGImage)?

    /// - Parameters:
    ///   - originalMasterURL: The real HLS master URL resolved for playback
    ///   - info: The trickplay resolution to synthesize the rendition from
    ///   - tileURL: Maps a tile-sheet index to its authenticated URL
    ///     (`JellyfinClientProtocol.trickplayTileURL`)
    ///   - protocolClasses: Test seam — `URLProtocol` stubs standing in for
    ///     the Jellyfin origin
    init(
        originalMasterURL: URL,
        info: TrickplayInfo,
        tileURL: @escaping @Sendable (Int) -> URL?,
        protocolClasses: [AnyClass]? = nil,
    ) {
        self.originalMasterURL = originalMasterURL
        self.info = info
        self.tileURL = tileURL

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = .shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration)
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start listening on an ephemeral loopback port
    /// - Returns: The interposed master playlist URL, or nil if the listener
    ///   could not start (callers fall back to the original URL)
    func start() async -> URL? {
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters)
        } catch {
            Self.logger.warning("[server] failed to create listener: \(error, privacy: .public)")
            return nil
        }

        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let port: UInt16? = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }

        guard let port else {
            Self.logger.warning("[server] listener failed to become ready")
            stop()
            return nil
        }

        Self.logger.info("[server] listening on 127.0.0.1:\(port) (width=\(self.info.widthKey), thumbnails=\(self.info.thumbnailCount))")
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [connections] in
            for connection in connections.values {
                connection.cancel()
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        // Delivered on `queue` (the queue the connection starts on), where
        // the connections dictionary is always accessed
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.drop(connection)
            } else if case .cancelled = state {
                self.connections[ObjectIdentifier(connection)] = nil
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                self?.drop(connection)
                return
            }

            // GET requests fit comfortably in one read; only the request
            // line matters
            let head = String(decoding: data, as: UTF8.self)
            guard let requestLine = head.split(separator: "\r\n").first,
                  requestLine.hasPrefix("GET "),
                  let path = requestLine.split(separator: " ").dropFirst().first
            else {
                self.drop(connection)
                return
            }

            Task { await self.route(path: String(path), on: connection) }
        }
    }

    // MARK: - Routing

    private func route(path: String, on connection: NWConnection) async {
        Self.logger.debug("[server] GET \(path, privacy: .public)")
        switch path {
        case "/master.m3u8":
            await serveMaster(on: connection)
        case "/iframe.m3u8":
            send(body: Data(iframePlaylist().utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
        case "/init.mp4":
            let segment = TrickplayIFrameMuxer.initializationSegment(
                thumbnailWidth: info.thumbnailWidth,
                thumbnailHeight: info.thumbnailHeight,
                durationMilliseconds: info.thumbnailCount * info.intervalMilliseconds,
            )
            send(body: segment, contentType: "video/mp4", on: connection)
        default:
            if let index = segmentIndex(fromPath: path) {
                await serveSegment(thumbnailIndex: index, on: connection)
            } else {
                send(status: "404 Not Found", on: connection)
            }
        }
    }

    private func serveMaster(on connection: NWConnection) async {
        do {
            var request = URLRequest(url: originalMasterURL)
            // The master reflects live stream parameters; never reuse a
            // stale copy from the artwork cache
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await session.data(for: request)
            guard let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }

            guard let rewritten = TrickplayHLSPlaylist.rewriteMaster(
                text,
                originalURL: originalMasterURL,
                iframePlaylistURI: "/iframe.m3u8",
                info: info,
            ) else {
                // A media playlist where a master was expected is a
                // server-shape regression (this input used to crash
                // MediaToolbox) — name it before the generic catch below
                // reduces it to a URL error code
                Self.logger.warning("[server] origin response is not a master playlist (no #EXT-X-STREAM-INF); refusing to interpose")
                throw URLError(.cannotParseResponse)
            }
            send(body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", on: connection)
        } catch {
            // Playback must survive a trickplay failure: bounce the player
            // to the real master and give up on thumbnails for this session
            Self.logger.warning("[server] master rewrite failed, redirecting to origin: \(error, privacy: .public)")
            send(status: "302 Found", headers: ["Location": originalMasterURL.absoluteString], on: connection)
        }
    }

    private func iframePlaylist() -> String {
        TrickplayHLSPlaylist.iframePlaylist(
            info: info,
            initializationURI: "/init.mp4",
        ) { "/seg\($0).m4s" }
    }

    // MARK: - Segments

    private func segmentIndex(fromPath path: String) -> Int? {
        guard path.hasPrefix("/seg"), path.hasSuffix(".m4s") else {
            return nil
        }
        return Int(path.dropFirst(4).dropLast(4))
    }

    private func serveSegment(thumbnailIndex: Int, on connection: NWConnection) async {
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
            send(body: segment, contentType: "video/mp4", on: connection)
        } catch {
            // Costs one preview frame; playback is unaffected
            Self.logger.debug("[server] segment \(thumbnailIndex) failed: \(error, privacy: .public)")
            send(status: "404 Not Found", on: connection)
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

    // MARK: - HTTP plumbing

    private func send(
        status: String = "200 OK",
        headers: [String: String] = [:],
        body: Data = Data(),
        contentType: String? = nil,
        on connection: NWConnection,
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.drop(connection)
        })
    }

    private func send(body: Data, contentType: String, on connection: NWConnection) {
        send(status: "200 OK", body: body, contentType: contentType, on: connection)
    }
}

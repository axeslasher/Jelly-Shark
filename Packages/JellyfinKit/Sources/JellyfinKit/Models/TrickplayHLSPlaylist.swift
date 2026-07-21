import Foundation

/// Builds the HLS playlist text for trickplay seek previews
///
/// Jellyfin's master playlist advertises trickplay only as a Roku-style
/// `EXT-X-IMAGE-STREAM-INF`, which AVFoundation ignores. To get native scrub
/// thumbnails, `TrickplayLocalServer` interposes the master playlist: every
/// URI is made absolute (the rewritten playlist is served from a loopback
/// host, so relative references would break), and an `mjpg` I-frame
/// rendition — synthesized client-side by `TrickplayIFrameMuxer` — is
/// appended.
///
/// Pure text processing with no networking, so it is fully unit-testable.
public enum TrickplayHLSPlaylist {
    /// The result of a master rewrite: the playlist text plus the origin
    /// URLs of any subtitle renditions that were redirected to local routes
    /// (index-aligned with the URIs `localSubtitleURI` produced)
    public struct MasterRewrite: Sendable, Equatable {
        public let playlist: String
        public let subtitleOriginURLs: [URL]

        public init(playlist: String, subtitleOriginURLs: [URL]) {
            self.playlist = playlist
            self.subtitleOriginURLs = subtitleOriginURLs
        }
    }

    /// Rewrite a master playlist for interposed delivery
    /// - Parameters:
    ///   - master: The original master playlist text from the server
    ///   - originalURL: The URL the master was fetched from; relative URIs
    ///     resolve against it
    ///   - iframePlaylistURI: URI for the synthesized I-frame media playlist
    ///     (relative to the interposed master, e.g. `/iframe.m3u8`)
    ///   - info: The trickplay resolution backing the I-frame rendition;
    ///     nil skips the I-frame appendix (sessions without seek-preview
    ///     data still need the subtitle interposition)
    ///   - localSubtitleURI: Maps the n-th subtitle rendition to a local
    ///     route; nil leaves subtitle URIs absolutized to the origin
    /// - Returns: The rewrite, or nil if the input is not a master playlist
    ///   and therefore cannot be interposed on
    public static func rewriteMaster(
        _ master: String,
        originalURL: URL,
        iframePlaylistURI: String,
        info: TrickplayInfo?,
        localSubtitleURI: ((Int) -> String)? = nil,
    ) -> MasterRewrite? {
        // Only a master playlist can carry `EXT-X-I-FRAME-STREAM-INF`.
        // Appending one to a media playlist yields a file with both media-
        // and master-playlist tags, which does not merely fail to parse —
        // MediaToolbox reads a null media playlist and crashes the app
        // (`FigMediaPlaylistGetTargetDuration`, EXC_BAD_ACCESS). And a
        // media playlist has no renditions to redirect. Refusing here turns
        // both into a graceful fall back to the origin stream.
        guard master.contains("#EXT-X-STREAM-INF") else {
            return nil
        }

        var subtitleOriginURLs: [URL] = []
        var lines = master
            .split(separator: "\n", omittingEmptySubsequences: false)
            // Drop the Roku-style image rendition: AVFoundation ignores it at
            // best, and the synthesized I-frame rendition replaces it
            .filter { !$0.hasPrefix("#EXT-X-IMAGE-STREAM-INF") }
            .map { rawLine -> String in
                let line = String(rawLine)
                if let localSubtitleURI, isSubtitleRendition(line),
                   let range = uriAttributeRange(in: line),
                   let origin = URL(string: String(line[range]), relativeTo: originalURL)
                {
                    subtitleOriginURLs.append(origin)
                    let local = localSubtitleURI(subtitleOriginURLs.count - 1)
                    return line.replacingCharacters(in: range, with: local)
                }
                return absolutize(line: line, against: originalURL)
            }

        // Drop a trailing blank line so the appended tag stays inside the file
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        if let info {
            let bandwidth = info.bandwidth ?? 50000
            lines.append(
                "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"mjpg\","
                    + "RESOLUTION=\(info.thumbnailWidth)x\(info.thumbnailHeight),"
                    + "URI=\"\(iframePlaylistURI)\"",
            )
        }
        return MasterRewrite(
            playlist: lines.joined(separator: "\n") + "\n",
            subtitleOriginURLs: subtitleOriginURLs,
        )
    }

    private static func isSubtitleRendition(_ line: String) -> Bool {
        line.hasPrefix("#EXT-X-MEDIA") && line.contains("TYPE=SUBTITLES")
    }

    /// The I-frame media playlist for a trickplay resolution: one discrete
    /// single-thumbnail segment per interval
    /// - Parameters:
    ///   - info: The trickplay resolution
    ///   - initializationURI: URI of the muxer's initialization segment
    ///   - segmentURI: URI for the media segment at a thumbnail index
    /// - Returns: The media playlist text
    public static func iframePlaylist(
        info: TrickplayInfo,
        initializationURI: String,
        segmentURI: (Int) -> String,
    ) -> String {
        let intervalSeconds = Double(info.intervalMilliseconds) / 1000
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(intervalSeconds.rounded(.up)))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-I-FRAMES-ONLY",
            "#EXT-X-MAP:URI=\"\(initializationURI)\"",
        ]
        for index in 0 ..< info.thumbnailCount {
            lines.append(String(format: "#EXTINF:%.3f,", intervalSeconds))
            lines.append(segmentURI(index))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Make one playlist line's URI absolute: plain URI lines are resolved
    /// wholesale; tag lines have any `URI="..."` attribute resolved in place
    private static func absolutize(line: String, against base: URL) -> String {
        if line.isEmpty {
            return line
        }

        guard line.hasPrefix("#") else {
            return resolve(uri: line, against: base)
        }

        guard let range = uriAttributeRange(in: line) else {
            return line
        }
        let resolved = resolve(uri: String(line[range]), against: base)
        return line.replacingCharacters(in: range, with: resolved)
    }

    /// The character range inside the quotes of a `URI="..."` attribute
    private static func uriAttributeRange(in line: String) -> Range<String.Index>? {
        guard let attribute = line.range(of: "URI=\"") else {
            return nil
        }
        guard let closingQuote = line.range(of: "\"", range: attribute.upperBound ..< line.endIndex) else {
            return nil
        }
        return attribute.upperBound ..< closingQuote.lowerBound
    }

    private static func resolve(uri: String, against base: URL) -> String {
        URL(string: uri, relativeTo: base)?.absoluteString ?? uri
    }
}

import Foundation

/// Rewrites a Jellyfin subtitle media playlist for interposed delivery
///
/// Jellyfin stamps every WebVTT segment with
/// `X-TIMESTAMP-MAP=MPEGTS:900000` — a 10s PTS offset that only lines up
/// against MPEG-TS video segments. The map is not a property of the VTT:
/// it is added per request by the `AddVttTimeMap` query parameter the
/// server puts on each segment URI in the playlist it generates. Cue
/// times themselves are in real media time (`CopyTimestamps=true`), so a
/// segment fetched *without* the parameter is correctly timed against
/// fMP4's zero-based timeline.
///
/// The loopback server therefore proxies only this playlist: segment URIs
/// are absolutized to the origin with `AddVttTimeMap` removed, and the VTT
/// bodies themselves never transit the proxy. See issue #90.
///
/// Pure text processing with no networking, so it is fully unit-testable.
public enum SubtitleHLSPlaylist {
    /// Rewrite a subtitle media playlist: absolutize each segment URI
    /// against the origin playlist URL and strip its `AddVttTimeMap`
    /// parameter. Tag lines pass through untouched.
    public static func rewrite(_ playlist: String, originalURL: URL) -> String {
        let lines = playlist
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard !text.isEmpty, !text.hasPrefix("#") else {
                    return text
                }
                return rewriteSegmentURI(text, against: originalURL)
            }
        return lines.joined(separator: "\n")
    }

    private static func rewriteSegmentURI(_ uri: String, against base: URL) -> String {
        guard let absolute = URL(string: uri, relativeTo: base),
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: true)
        else {
            return uri
        }
        components.queryItems = components.queryItems?.filter {
            $0.name.caseInsensitiveCompare("AddVttTimeMap") != .orderedSame
        }
        return components.url?.absoluteString ?? uri
    }
}

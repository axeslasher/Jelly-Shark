import Foundation

/// Rewrites a Jellyfin subtitle media playlist for interposed delivery
///
/// Jellyfin stamps every WebVTT segment with
/// `X-TIMESTAMP-MAP=MPEGTS:900000` — a 10s PTS offset that only lines up
/// against MPEG-TS video segments. The map is not a property of the VTT:
/// it is added per request by the `AddVttTimeMap` query parameter the
/// server puts on each segment URI in the playlist it generates. Cue
/// times themselves are in real media time (`CopyTimestamps=true`).
///
/// So the correct handling depends on the *video* segment container:
/// - **fMP4** (HEVC path): the video timeline is zero-based, so the 10s map
///   offset makes cues late — the parameter must be stripped (`stripTimestampMap: true`).
/// - **TS** (H.264 path): the video PTS starts at the same offset the map
///   encodes, so the map lines cues up correctly and must be **kept**.
///
/// The loopback server proxies only this playlist: segment URIs are
/// absolutized to the origin (with `AddVttTimeMap` removed only when
/// stripping), and the VTT bodies themselves never transit the proxy. See
/// issues #90 (fMP4 strip) and the H.264→TS frameskip fix.
///
/// Pure text processing with no networking, so it is fully unit-testable.
public enum SubtitleHLSPlaylist {
    /// Rewrite a subtitle media playlist: absolutize each segment URI against
    /// the origin playlist URL, stripping `AddVttTimeMap` only when
    /// `stripTimestampMap` is true (fMP4). Tag lines pass through untouched.
    public static func rewrite(_ playlist: String, originalURL: URL, stripTimestampMap: Bool) -> String {
        let lines = playlist
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard !text.isEmpty, !text.hasPrefix("#") else {
                    return text
                }
                return rewriteSegmentURI(text, against: originalURL, stripTimestampMap: stripTimestampMap)
            }
        return lines.joined(separator: "\n")
    }

    private static func rewriteSegmentURI(_ uri: String, against base: URL, stripTimestampMap: Bool) -> String {
        guard let absolute = URL(string: uri, relativeTo: base),
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: true)
        else {
            return uri
        }
        if stripTimestampMap {
            components.queryItems = components.queryItems?.filter {
                $0.name.caseInsensitiveCompare("AddVttTimeMap") != .orderedSame
            }
        }
        return components.url?.absoluteString ?? uri
    }
}

import Foundation

/// Extracts the stream-copy variant from a Jellyfin master playlist (#172).
///
/// The HDR eligibility gate fires at variant selection over the master's
/// declared attributes, so an HDR copy variant is unreachable through the
/// master on an SDR display — but the variant's own media playlist, loaded
/// directly, never reaches variant selection. Measured 2026-08-02 on the
/// SDR-panel rig: the copy variant's `main.m3u8` for a 4K Dolby Vision
/// profile 7 source (served as PQ, audio transcoded DTS→AC3) reached
/// `readyToPlay` in 4s and sustained rate 1.0 with the buffer 100s ahead,
/// while the server copied at 9.89× realtime — against the 0.88× starving
/// tone-map re-encode the same session gets through the master.
///
/// Jellyfin marks the distinction in the variant URI itself: the copy
/// variant carries `AllowVideoStreamCopy=true`, the injected re-encode
/// fallbacks carry `false` (#146 recorded this shape).
public enum HLSMasterCopyVariant {
    /// The URI line of the first variant whose query declares
    /// `AllowVideoStreamCopy=true`, or nil when the master offers no copy
    /// variant (source range outside the declared capabilities, burn-in
    /// subtitles, or a non-Jellyfin master).
    public static func uri(inMaster master: String) -> String? {
        var previousWasStreamInf = false
        for rawLine in master.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                previousWasStreamInf = true
                continue
            }
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if previousWasStreamInf {
                if line.range(of: "AllowVideoStreamCopy=true", options: .caseInsensitive) != nil {
                    return line
                }
                previousWasStreamInf = false
            }
        }
        return nil
    }
}

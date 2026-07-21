import Foundation
import JellyfinKit

/// Menu copy for burn-in subtitle tracks: "English (PGS)" rather than
/// Jellyfin's technical DisplayTitle ("English - Default - PGSSUB")
enum BurnInSubtitleLabel {
    /// Codec identifiers mapped to the names people know them by
    private static let formatNames: [String: String] = [
        "pgssub": "PGS",
        "pgs": "PGS",
        "dvdsub": "VobSub",
        "dvbsub": "DVB",
        "xsub": "XSUB",
    ]

    static func title(for stream: MediaStreamInfo) -> String {
        let language = stream.language
            .flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            ?? stream.language
            ?? stream.displayTitle
            ?? "Track \(stream.index)"

        guard let codec = stream.codec?.lowercased() else {
            return language
        }
        let format = formatNames[codec] ?? codec.uppercased()
        return "\(language) (\(format))"
    }
}

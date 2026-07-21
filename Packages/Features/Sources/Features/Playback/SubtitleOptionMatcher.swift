import Foundation
import JellyfinKit

/// A legible media-selection option distilled to the values needed to
/// correlate it with a Jellyfin subtitle stream, keeping the matching
/// logic free of AVFoundation types so it stays unit-testable.
struct LegibleOption: Equatable {
    /// Position within the AVMediaSelectionGroup's options
    let position: Int

    /// The option's display name (Jellyfin sets the rendition NAME to the
    /// stream's DisplayTitle, so this usually matches exactly)
    let displayName: String

    /// BCP-47 or ISO-639 language tag, if the option declares one
    let languageTag: String?
}

/// Correlates a Jellyfin subtitle stream with the HLS master playlist's
/// legible renditions as AVPlayer exposes them.
enum SubtitleOptionMatcher {
    /// The position of the option matching the target stream, or nil when
    /// no confident match exists (callers fall back to a stream rebuild).
    ///
    /// Priority: exact display-name match (the server mirrors DisplayTitle
    /// into the rendition NAME) → unambiguous language match → the sole
    /// option when there is exactly one.
    static func match(_ target: MediaStreamInfo, in options: [LegibleOption]) -> Int? {
        if let title = target.displayTitle,
           let hit = options.first(where: { $0.displayName == title })
        {
            return hit.position
        }

        if let language = baseLanguage(target.language) {
            let sameLanguage = options.filter { baseLanguage($0.languageTag) == language }
            if sameLanguage.count == 1 {
                return sameLanguage[0].position
            }
        }

        if options.count == 1 {
            return options[0].position
        }

        return nil
    }

    /// The reverse direction: the stream whose forward match lands on the
    /// selected option position, or nil unless exactly one does. Running the
    /// forward matcher per stream keeps both directions agreeing by
    /// construction — a stream the forward pass can't place can't be
    /// reconciled either.
    static func streamIndex(
        forSelectedPosition position: Int,
        streams: [MediaStreamInfo],
        options: [LegibleOption],
    ) -> Int? {
        let hits = streams.filter { match($0, in: options) == position }
        return hits.count == 1 ? hits[0].index : nil
    }

    /// Normalize a language tag to a comparable base form: Jellyfin streams
    /// carry ISO-639-2 codes ("eng") while AVFoundation options report
    /// BCP-47 tags ("en"), so both sides map through alpha-2 when known.
    private static func baseLanguage(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        let base = tag.split(separator: "-").first.map(String.init) ?? tag
        let code = Locale.LanguageCode(base)
        return code.identifier(.alpha2) ?? base.lowercased()
    }
}

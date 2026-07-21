import Foundation
import JellyfinKit

/// An audible media-selection option distilled to the values needed to
/// correlate it with a Jellyfin audio stream, mirroring `LegibleOption` so
/// the matching logic stays free of AVFoundation types.
struct AudibleOption: Equatable {
    /// Position within the AVMediaSelectionGroup's options
    let position: Int

    /// The option's display name. HLS renditions carry the stream's
    /// DisplayTitle; a direct-played file's embedded tracks report whatever
    /// the container stores, which rarely matches Jellyfin's naming.
    let displayName: String

    /// BCP-47 or ISO-639 language tag, if the option declares one
    let languageTag: String?
}

/// Correlates an audible media-selection option with a Jellyfin audio
/// stream. Only the reverse direction exists: the app never selects audio
/// in place (audio switches rebuild the stream server-side), so matching is
/// needed solely to reconcile a native-picker change back into view-model
/// state.
enum AudioOptionMatcher {
    /// The stream matching the selected option, or nil when no confident
    /// match exists (callers leave state untouched).
    ///
    /// Priority: exact display-name match (HLS renditions mirror
    /// DisplayTitle) → unambiguous language match → positional correlation.
    /// The positional tier carries the common multi-audio case — a file's
    /// mono/stereo/5.1 variants share one language and AVFoundation's names
    /// ("Stereo - English") don't equal Jellyfin's titles, but both sides
    /// list the embedded tracks in container order, so when the counts
    /// agree the ordinal is the mapping. A per-position language conflict
    /// vetoes it rather than reporting the wrong track.
    static func streamIndex(
        forSelectedOption option: AudibleOption,
        streams: [MediaStreamInfo],
        options: [AudibleOption],
    ) -> Int? {
        if let hit = streams.first(where: { $0.displayTitle == option.displayName }) {
            return hit.index
        }

        if let language = baseLanguage(option.languageTag) {
            let sameLanguage = streams.filter { baseLanguage($0.language) == language }
            if sameLanguage.count == 1 {
                return sameLanguage[0].index
            }
        }

        let ordered = streams.sorted { $0.index < $1.index }
        if ordered.count == options.count, ordered.indices.contains(option.position) {
            let candidate = ordered[option.position]
            let optionLanguage = baseLanguage(option.languageTag)
            let streamLanguage = baseLanguage(candidate.language)
            if optionLanguage == nil || streamLanguage == nil || optionLanguage == streamLanguage {
                return candidate.index
            }
        }

        return nil
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

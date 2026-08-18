import Foundation
import JellyfinKit

/// Sanitization for Playback's public logs.
///
/// One policy, two entry points: anything that may embed a credentialed URL
/// goes through `redacting(_:)`, and `error(_:)` layers the `NSError` guard on
/// top of it. Interpolating an `Error` directly asks `NSError` for its full
/// description including `userInfo`, and URL loading errors put the failing
/// URL — `api_key` and all — there (#244).
enum PlaybackLog {
    /// Credential-bearing query parameters, plain or percent-encoded.
    ///
    /// Matched on a name substring rather than an exact list so an unfamiliar
    /// parameter (`X-Emby-Token`, some future `*_secret`) redacts by default,
    /// and `%3D`/`%26` are honoured alongside `=`/`&` so an encoded URL cannot
    /// slip past. Everything else in the string survives: `static=true` and
    /// `AllowVideoStreamCopy=true` are exactly what the delivery logs are read
    /// for.
    ///
    /// Built per call rather than stored: `Regex` is not `Sendable` (its
    /// matching engine caches internally), and these are failure-path logs
    /// where one compile costs less than reasoning about a shared instance.
    private static var credential:
        Regex<(Substring, name: Substring, separator: Substring, value: Substring)>
    {
        #/(?i)(?<name>[A-Za-z0-9_\-]*(?:key|token|secret|password|auth)[A-Za-z0-9_\-]*)(?<separator>=|%3D)(?<value>(?:(?!%26)[^&\s"'<>,}\]])*)/#
    }

    /// `text` with every credential value replaced by `REDACTED`.
    static func redacting(_ text: String) -> String {
        text.replacing(credential) { "\($0.name)\($0.separator)REDACTED" }
    }

    /// A URL for a public log: structure and diagnostic parameters kept,
    /// credentials redacted.
    static func url(_ url: URL) -> String {
        redacting(url.absoluteString)
    }

    /// A bounded description of `error` for a public log.
    static func error(_ error: any Error) -> String {
        switch error {
        // The remuxer's errors are plain Swift enums carrying the diagnostic
        // in their payload (`unsupportedAudioCodec("dts")`); bridging them to
        // `NSError` would reduce them to a case index. Neither type can carry
        // a URL.
        case let error as MatroskaError:
            return "MatroskaError.\(error)"
        case let error as MatroskaFMP4Remuxer.RemuxError:
            return "RemuxError.\(error)"
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code): \(redacting(error.localizedDescription))"
        }
    }
}

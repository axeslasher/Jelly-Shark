import CryptoKit
import Foundation

/// What the affinity universe looked like when a shelf set was computed.
///
/// `librarySize` is the same count the denominator needs, so the stamp costs
/// no extra probe. It catches every change to the eligible library set and
/// every change to the universe's item count; a same-count swap and a
/// server-side metadata edit slip past it, and the denominator TTL is the
/// backstop for those.
public struct AffinityLibraryStamp: Sendable, Hashable, Codable {
    public let libraryIDs: [String]
    public let librarySize: Int

    public init(libraryIDs: [String], librarySize: Int) {
        self.libraryIDs = libraryIDs
        self.librarySize = librarySize
    }
}

/// A persistable digest of everything the engine was fed.
///
/// Deliberately **not** `Hashable`/`hashValue`: Swift's `Hasher` is randomly
/// seeded per process, so a persisted value would mismatch on every cold
/// start and recompute forever — defeating the mechanism it exists to serve.
public enum AffinityFingerprint {
    /// Field separator. A unit separator cannot occur in a Jellyfin id.
    private static let separator = "\u{1F}"

    public static func make(
        signals: [AffinitySignal],
        favoritedPeople: [Person],
        now: Date,
        stamp: AffinityLibraryStamp,
    ) -> String {
        var parts: [String] = []

        // Normalized signal ids (§ 5.1) — a movie's own id, or a series id
        // standing for however many episodes were played — so the digest
        // represents what the engine actually receives.
        parts.append(contentsOf: signals
            .map { "\($0.sourceID)=\(Int($0.lastPlayed?.timeIntervalSince1970 ?? -1))=\($0.isFavorite ? 1 : 0)" }
            .sorted())
        parts.append(separator)
        parts.append(contentsOf: favoritedPeople.map(\.id).sorted())
        parts.append(separator)
        parts.append(String(Int(now.timeIntervalSince1970 / 86400)))
        parts.append(separator)
        parts.append(contentsOf: stamp.libraryIDs.sorted())
        parts.append(String(stamp.librarySize))

        let canonical = parts.joined(separator: separator)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

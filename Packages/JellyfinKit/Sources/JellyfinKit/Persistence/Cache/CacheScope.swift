import Foundation

/// Identifies whose cache a row belongs to: one Jellyfin user on one server.
///
/// Every cached row is keyed by a scope so two users never see each other's
/// data — sign-out purges one scope, and saved profiles (#192) get one scope
/// per profile. The server URL is normalized so cosmetic variations of the
/// same address (host case, an explicit default port, a trailing slash) all
/// land in one scope instead of fragmenting the cache.
public struct CacheScope: Sendable, Hashable {
    /// The stable string cached rows are keyed by. Part of the on-disk
    /// format: changing how it is built requires a
    /// `MediaCacheStore.schemaVersion` bump.
    public let storageKey: String

    public init(serverURL: URL, userID: String) {
        // U+001F (unit separator) cannot appear in a URL or a Jellyfin user
        // id, so the two halves can never collide into another scope's key.
        storageKey = Self.normalizedServer(serverURL) + "\u{1F}" + userID
    }

    private static func normalizedServer(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let scheme = components.scheme, let port = components.port,
           (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        {
            components.port = nil
        }
        while components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? url.absoluteString
    }
}

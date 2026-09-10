import Foundation

/// One dimension the viewer's taste can be over-represented in.
///
/// The kind discriminator is the extension point, and it has a known first
/// client: #235 adds `case tag(String)`. Adding a kind must require no edit
/// to scoring, the threshold rule, the fingerprint, or shelf selection —
/// only a row in `identity`, a row in `archetypeRank`, an extraction rule,
/// and a filter on the count probe.
public enum AffinityBucket: Hashable, Sendable, Codable {
    case genre(String)
    /// Genre plus decade start year, e.g. `("Horror", 1980)`.
    case genreDecade(String, Int)
    /// A person id, always a real server id (never the `"person-N"` fallback).
    case person(String)

    /// Stable, unique across every kind. Used as the last tie-break in
    /// candidate ordering, so it must be a total order (see
    /// `AffinitySelection`).
    public var identity: String {
        switch self {
        case let .genre(name): "genre|\(name)"
        case let .genreDecade(name, decade): "genreDecade|\(name)|\(decade)"
        case let .person(id): "person|\(id)"
        }
    }

    /// Fixed ordering between kinds, applied after score in candidate
    /// ranking. #235's `.tag` takes 4 — the similar-items shelf holds 3.
    public var archetypeRank: Int {
        switch self {
        case .genre: 0
        case .genreDecade: 1
        case .person: 2
        }
    }
}

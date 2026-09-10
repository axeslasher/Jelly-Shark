import Foundation

/// What kind of shelf a descriptor names.
///
/// The similar-items shelf is not a bucket — it has no genre, no
/// denominator, and no over-representation ratio — so it carries its seed
/// instead and is scored by the seed's strongest qualifying bucket (§ 7.1).
public enum AffinityShelfKind: Hashable, Sendable, Codable {
    case bucket(AffinityBucket)
    case similar(seedID: String, seedName: String, wasPlayed: Bool)

    /// Stable and unique across every candidate, so candidate ordering is a
    /// total order and never falls through to input order.
    public var identity: String {
        switch self {
        case let .bucket(bucket): bucket.identity
        case let .similar(seedID, _, _): "similar|\(seedID)"
        }
    }

    /// Applied after score in ranking. Buckets take 0–2; #235's `.tag`
    /// takes 4.
    public var archetypeRank: Int {
        switch self {
        case let .bucket(bucket): bucket.archetypeRank
        case .similar: 3
        }
    }
}

/// One affinity shelf, as persisted and as rendered.
public struct AffinityShelfDescriptor: Hashable, Sendable, Codable, Identifiable {
    public let kind: AffinityShelfKind
    public let title: String
    public let score: Double
    /// Set for `.bucket(.person(_))` shelves, so a cold-cache render needs
    /// no `getPerson` round-trip.
    public let personName: String?

    public var id: String {
        kind.identity
    }

    public init(kind: AffinityShelfKind, title: String, score: Double, personName: String?) {
        self.kind = kind
        self.title = title
        self.score = score
        self.personName = personName
    }
}

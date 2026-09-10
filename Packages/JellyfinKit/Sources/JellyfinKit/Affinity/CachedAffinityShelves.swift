import Foundation

/// One persisted affinity shelf: what to title it, and what it showed.
///
/// Items are persisted, not just the descriptor. That is a focus decision
/// rather than a speed one — descriptor-only means every cold launch pops
/// three rows into the focus graph a second after paint.
public struct CachedAffinityShelf: Sendable, Hashable, Codable {
    public let descriptor: AffinityShelfDescriptor
    public let items: [MediaItem]

    public init(descriptor: AffinityShelfDescriptor, items: [MediaItem]) {
        self.descriptor = descriptor
        self.items = items
    }
}

/// The whole affinity cache row for one scope.
public struct CachedAffinityShelves: Sendable, Hashable, Codable {
    public let fingerprint: String
    public let stamp: AffinityLibraryStamp
    /// When `stamp` was last probed, against `AffinityTuning.stampTTL`.
    public let stampProbedAt: Date
    /// `libraryCount` per bucket. Stored beside the stamp that produced
    /// them: a count of one universe must never be read back against
    /// another.
    public let denominators: [AffinityBucket: Int]
    /// When the denominators were probed, against
    /// `AffinityTuning.denominatorTTL`.
    public let denominatorsProbedAt: Date
    public let shelves: [CachedAffinityShelf]

    public init(
        fingerprint: String,
        stamp: AffinityLibraryStamp,
        stampProbedAt: Date,
        denominators: [AffinityBucket: Int],
        denominatorsProbedAt: Date,
        shelves: [CachedAffinityShelf],
    ) {
        self.fingerprint = fingerprint
        self.stamp = stamp
        self.stampProbedAt = stampProbedAt
        self.denominators = denominators
        self.denominatorsProbedAt = denominatorsProbedAt
        self.shelves = shelves
    }
}

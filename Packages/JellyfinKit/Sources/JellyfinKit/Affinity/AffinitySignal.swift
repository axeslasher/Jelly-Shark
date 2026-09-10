import Foundation

/// One normalized taste statement: a movie, or a whole series standing for
/// however many of its episodes were played.
///
/// Normalization happens before any scoring, because the denominator
/// universe counts a series once (§ 5.3) and the numerator must agree. An
/// item that was both played and favorited is one signal carrying both
/// provenances, never two.
///
/// Favorited people are the existing `Person` model — `/Persons` returns
/// standalone person items, which is exactly what `Person` is. Not
/// `CastMember`: that is the embedded credit entry and requires a `kind` a
/// standalone person does not have.
public struct AffinitySignal: Sendable, Equatable {
    /// A movie's own id, or the series id an episode run collapsed to.
    public let sourceID: String
    public let name: String
    public let buckets: Set<AffinityBucket>
    /// Names for this signal's person buckets, so a shelf title survives a
    /// cold cache without a `getPerson` round-trip.
    public let personNames: [String: String]
    /// Most recent play, or nil for a favorite that was never played.
    public let lastPlayed: Date?
    public let isFavorite: Bool

    public init(
        sourceID: String,
        name: String,
        buckets: Set<AffinityBucket>,
        personNames: [String: String],
        lastPlayed: Date?,
        isFavorite: Bool,
    ) {
        self.sourceID = sourceID
        self.name = name
        self.buckets = buckets
        self.personNames = personNames
        self.lastPlayed = lastPlayed
        self.isFavorite = isFavorite
    }
}

import Foundation

/// A person (actor, director, etc.) as a full library entity.
///
/// Persons are items on the server, so `id` is a regular item ID usable with
/// the standard image endpoint. Distinct from `CastMember`, which is the
/// lightweight credit entry embedded in a media item's people list; a `Person`
/// carries the biographical detail fetched for a person page.
public struct Person: Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for the person (usable as an item ID for image URLs)
    public let id: String

    /// Display name of the person
    public let name: String

    /// Biography (the server's `Overview` field for person items)
    public let biography: String?

    /// Birth date (the server's `PremiereDate` field for person items)
    public let birthDate: Date?

    /// Death date (the server's `EndDate` field); nil while living
    public let deathDate: Date?

    /// Birthplace (the first of the server's `ProductionLocations`)
    public let birthPlace: String?

    /// Primary image tag, or nil when the person has no headshot
    public let primaryImageTag: String?

    /// BlurHash for the primary image, when the server provides one
    public let primaryBlurHash: String?

    /// Whether the current user has favorited this person
    public let isFavorite: Bool

    public init(
        id: String,
        name: String,
        biography: String? = nil,
        birthDate: Date? = nil,
        deathDate: Date? = nil,
        birthPlace: String? = nil,
        primaryImageTag: String? = nil,
        primaryBlurHash: String? = nil,
        isFavorite: Bool = false,
    ) {
        self.id = id
        self.name = name
        self.biography = biography
        self.birthDate = birthDate
        self.deathDate = deathDate
        self.birthPlace = birthPlace
        self.primaryImageTag = primaryImageTag
        self.primaryBlurHash = primaryBlurHash
        self.isFavorite = isFavorite
    }
}

// MARK: - Computed Properties

public extension Person {
    /// Birth date formatted for display (e.g., "May 4, 1929")
    var formattedBirthDate: String? {
        birthDate?.formatted(date: .long, time: .omitted)
    }

    /// Death date formatted for display (e.g., "January 20, 1993")
    var formattedDeathDate: String? {
        deathDate?.formatted(date: .long, time: .omitted)
    }

    /// Age in years — at death when `deathDate` is set, otherwise current.
    /// Nil without a birth date.
    var age: Int? {
        guard let birthDate else { return nil }
        return Calendar(identifier: .gregorian)
            .dateComponents([.year], from: birthDate, to: deathDate ?? Date()).year
    }
}

import Foundation

/// A person credited on a media item (cast or crew).
///
/// Created from the SDK's `BaseItemPerson` via the adapter layer. Person IDs are
/// item IDs in Jellyfin, so a headshot URL can be built with the standard image
/// endpoint when `primaryImageTag` is present.
public struct CastMember: Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for the person (usable as an item ID for image URLs)
    public let id: String

    /// Display name of the person
    public let name: String

    /// Character name for actors (e.g., "Neo"); nil for most crew
    public let role: String?

    /// Credit kind (e.g., "Actor", "Director", "Writer")
    public let kind: String

    /// Primary image tag, or nil when the person has no headshot
    public let primaryImageTag: String?

    public init(
        id: String,
        name: String,
        role: String? = nil,
        kind: String,
        primaryImageTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.kind = kind
        self.primaryImageTag = primaryImageTag
    }
}

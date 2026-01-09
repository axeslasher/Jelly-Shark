import Foundation

/// Represents a Jellyfin user
///
/// This is a clean, app-specific representation of a user.
/// It is created from the SDK's UserDto via the adapter layer.
public struct User: Identifiable, Sendable, Equatable, Hashable {
    /// Unique identifier for the user
    public let id: String

    /// Display name of the user
    public let name: String

    /// Server ID this user belongs to
    public let serverId: String?

    /// Whether this user is an administrator
    public let isAdministrator: Bool

    /// Tag for the user's profile image
    public let primaryImageTag: String?

    public init(
        id: String,
        name: String,
        serverId: String? = nil,
        isAdministrator: Bool = false,
        primaryImageTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.isAdministrator = isAdministrator
        self.primaryImageTag = primaryImageTag
    }
}

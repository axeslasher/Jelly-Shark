import Foundation

/// Represents a Jellyfin user
public struct User: Identifiable, Sendable, Codable, Equatable {
    /// Unique identifier for the user
    public let id: String

    /// Display name of the user
    public let name: String

    /// Server ID this user belongs to
    public let serverId: String?

    /// Whether this user is an administrator
    public let isAdministrator: Bool

    /// URL to the user's profile image
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

// MARK: - Codable

extension User {
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case isAdministrator = "Policy"
        case primaryImageTag = "PrimaryImageTag"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId)
        primaryImageTag = try container.decodeIfPresent(String.self, forKey: .primaryImageTag)

        // Policy is a nested object in the API
        if let policy = try? container.nestedContainer(keyedBy: PolicyCodingKeys.self, forKey: .isAdministrator) {
            isAdministrator = (try? policy.decode(Bool.self, forKey: .isAdministrator)) ?? false
        } else {
            isAdministrator = false
        }
    }

    private enum PolicyCodingKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator"
    }
}

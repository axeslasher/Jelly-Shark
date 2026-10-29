import Foundation

/// Information about a Jellyfin server
public struct ServerInfo: Sendable, Codable, Equatable {
    /// Display name of the server
    public let serverName: String

    /// Server version
    public let version: String

    /// Server ID
    public let id: String

    /// Operating system the server is running on
    public let operatingSystem: String?

    /// Whether the server has been set up
    public let startupWizardCompleted: Bool?

    public init(
        serverName: String,
        version: String,
        id: String,
        operatingSystem: String? = nil,
        startupWizardCompleted: Bool? = nil,
    ) {
        self.serverName = serverName
        self.version = version
        self.id = id
        self.operatingSystem = operatingSystem
        self.startupWizardCompleted = startupWizardCompleted
    }

    /// Minimum supported Jellyfin server version: the release the app was
    /// built and measured against
    public static let minimumVersion = "10.11.11"

    /// Check if this server version is supported
    public var isSupported: Bool {
        compareVersions(version, Self.minimumVersion) >= 0
    }
}

// MARK: - Codable

extension ServerInfo {
    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
        case operatingSystem = "OperatingSystem"
        case startupWizardCompleted = "StartupWizardCompleted"
    }
}

// MARK: - Version Comparison

/// Compare two dotted version strings
///
/// Each component counts by its leading digits, so a suffix is ignored
/// ("10.11.11-rc1" compares as 10.11.11) and missing components count as
/// zero ("10.12" is 10.12.0). Parsing stops at the first component with no
/// leading digit, so an unparseable version compares as 0 and is rejected.
/// - Returns: negative if v1 < v2, 0 if equal, positive if v1 > v2
private func compareVersions(_ v1: String, _ v2: String) -> Int {
    let components1 = versionComponents(v1)
    let components2 = versionComponents(v2)

    let maxLength = max(components1.count, components2.count)

    for i in 0 ..< maxLength {
        let c1 = i < components1.count ? components1[i] : 0
        let c2 = i < components2.count ? components2[i] : 0

        if c1 != c2 {
            return c1 - c2
        }
    }

    return 0
}

private func versionComponents(_ version: String) -> [Int] {
    var components: [Int] = []
    for part in version.split(separator: ".", omittingEmptySubsequences: false) {
        guard let number = Int(part.prefix { $0.isASCII && $0.isNumber }) else { break }
        components.append(number)
    }
    return components
}

import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

/// The minimum-version gate sign-in applies (#322)
@Suite("ServerInfo version support")
struct ServerInfoTests {
    private func info(_ version: String) -> ServerInfo {
        ServerInfo(serverName: "Test", version: version, id: "server-1")
    }

    @Test("The minimum is 10.11.11")
    func minimumIs10_11_11() {
        #expect(ServerInfo.minimumVersion == "10.11.11")
    }

    @Test("Versions below 10.11.11 are rejected", arguments: [
        "10.11.10", "10.11.0", "10.10.7", "10.8.0", "9.99.99",
    ])
    func olderVersionsRejected(version: String) {
        #expect(!info(version).isSupported)
    }

    @Test("10.11.11 and later are accepted", arguments: [
        "10.11.11", "10.11.12", "10.12.0", "12.2.0", "12.4.0", "13.0.0",
    ])
    func newerVersionsAccepted(version: String) {
        #expect(info(version).isSupported)
    }

    /// A suffix counts by its leading digits, so a pre-release of the
    /// minimum is treated as the minimum. Jellyfin reports a plain
    /// three-part version (12.4.0 and 13.0.0 on the demo servers), so this
    /// only keeps an odd build from being misread.
    @Test("A suffixed component counts by its leading digits", arguments: [
        ("10.11.11-rc1", true),
        ("10.11.12-beta", true),
        ("10.11.10-rc1", false),
    ])
    func suffixedVersions(version: String, supported: Bool) {
        #expect(info(version).isSupported == supported)
    }

    @Test("Missing components count as zero; extra ones count", arguments: [
        ("10.11", false),
        ("10.12", true),
        ("11", true),
        ("10.11.11.0", true),
        ("10.11.10.9", false),
    ])
    func componentCounts(version: String, supported: Bool) {
        #expect(info(version).isSupported == supported)
    }

    @Test("An unparseable version is rejected", arguments: ["", "unknown", "v10.11.11"])
    func unparseableRejected(version: String) {
        #expect(!info(version).isSupported)
    }

    @Test("The error message names the minimum from the constant")
    func errorMessageUsesConstant() {
        let message = APIError.unsupportedServerVersion("10.11.10").localizedDescription
        #expect(message == "Server version 10.11.10 is not supported. Minimum required: \(ServerInfo.minimumVersion)")
    }

    @Test("Public system info maps to ServerInfo; a missing version is rejected")
    func adapterMapsPublicSystemInfo() throws {
        // Response body from https://demo.jellyfin.org/stable/System/Info/Public, 2026-10-29
        let json = Data("""
        {"LocalAddress":"http://172.17.0.2:8096/stable","ServerName":"Stable Demo","Version":"12.4.0",\
        "ProductName":"Jellyfin Server","OperatingSystem":"","Id":"f0b3381645f04afb9a0e392e74b6a1b0",\
        "StartupWizardCompleted":true}
        """.utf8)
        let mapped = try ServerInfo(from: JSONDecoder().decode(PublicSystemInfo.self, from: json))
        #expect(mapped.version == "12.4.0")
        #expect(mapped.serverName == "Stable Demo")
        #expect(mapped.isSupported)

        let versionless = ServerInfo(from: PublicSystemInfo(serverName: "No Version"))
        #expect(versionless.version == "unknown")
        #expect(!versionless.isSupported)
    }
}

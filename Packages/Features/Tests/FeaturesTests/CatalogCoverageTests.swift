import Foundation
import Testing

/// Every string the app looks up in a package catalog exists there.
///
/// A key missing from the catalog displays as the key itself
/// ("home.shelf.nextUp"), and nothing else fails. The lookups sit inline in
/// views, out of a test's reach, so this reads the sources instead: each
/// `bundle: #bundle` lookup in Features and DesignSystem must name a key that
/// module's `Localizable.xcstrings` defines.
@Suite("String catalog coverage")
struct CatalogCoverageTests {
    /// `Packages/`, from this file's place in the checkout
    private static let packages = URL(filePath: #filePath)
        .deletingLastPathComponent() // FeaturesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Features
        .deletingLastPathComponent() // Packages

    @Test("Every catalog lookup names a key its module defines", arguments: ["Features", "DesignSystem"])
    func lookupsResolve(module: String) throws {
        let sources = Self.packages.appending(path: "\(module)/Sources/\(module)")
        let catalog = try Self.catalogKeyBases(at: sources.appending(path: "Localizable.xcstrings"))
        let lookups = try Self.lookupKeyBases(under: sources)
        #expect(!lookups.isEmpty, "Found no lookups under \(sources.path()) — is the checkout where #filePath says?")
        for (key, file) in lookups.sorted(by: { $0.key < $1.key }) {
            #expect(catalog.contains(key), "\(file) looks up \"\(key)\", which \(module)'s catalog doesn't define")
        }
    }

    /// A key up to its first argument: "home.shelf.recentlyAddedIn %@" and
    /// "home.shelf.recentlyAddedIn \(name)" both become the same base
    private static func base(of key: Substring) -> String {
        String(key.split(separator: " ", maxSplits: 1).first ?? key)
    }

    private static func catalogKeyBases(at url: URL) throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any])
        return Set(strings.keys.map { base(of: Substring($0)) })
    }

    /// Lookup keys found in the module's Swift sources, with the file each
    /// came from. Only lookups that pass `bundle: #bundle` count: preview
    /// sample text is a bare literal and is never looked up.
    private static func lookupKeyBases(under directory: URL) throws -> [String: String] {
        let pattern = try Regex(#"(?:LocalizedStringResource|String\(localized:|Text)\(\s*"([^"]+)"(?:[^"\n]|"[^"\n]*")*?bundle: #bundle"#)
        var found: [String: String] = [:]
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                guard let key = match.output[1].substring else { continue }
                // Only semantic keys ("area.thing"); a sentence used as its
                // own key predates the convention and is checked by eye
                guard key.contains("."), !key.contains(" ") || key.split(separator: " ").first?.contains(".") == true else { continue }
                found[base(of: key)] = file.lastPathComponent
            }
        }
        return found
    }
}

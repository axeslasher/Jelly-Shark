import Foundation
import Testing

/// Every string the app looks up in a package catalog exists there.
///
/// A key missing from the catalog displays as the key itself
/// ("home.shelf.nextUp"), and nothing else fails. The lookups sit inline in
/// views, out of a test's reach, so this reads the sources instead: each
/// `bundle: #bundle` lookup in Features and DesignSystem must name a key, with
/// the same number of arguments, that the module's `Localizable.xcstrings`
/// defines. An argument of the wrong type (`%@` against `%lld`) still gets
/// past it.
@Suite("String catalog coverage")
struct CatalogCoverageTests {
    /// `Packages/`, from this file's place in the checkout
    private static let packages = URL(filePath: #filePath)
        .deletingLastPathComponent() // FeaturesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Features
        .deletingLastPathComponent() // Packages

    /// A key reduced to what the source and the catalog both spell the same
    /// way: the text up to its first argument, and how many arguments follow
    private struct Signature: Hashable, CustomStringConvertible {
        let base: String
        let arguments: Int

        var description: String {
            arguments == 0 ? base : "\(base) (\(arguments) arguments)"
        }
    }

    @Test("Every catalog lookup names a key its module defines", arguments: ["Features", "DesignSystem"])
    func lookupsResolve(module: String) throws {
        let sources = Self.packages.appending(path: "\(module)/Sources/\(module)")
        let catalog = try Self.catalogSignatures(at: sources.appending(path: "Localizable.xcstrings"))
        let lookups = try Self.lookupSignatures(under: sources)
        #expect(lookups.count > 10, "Found only \(lookups.count) lookups under \(sources.path()): is the checkout where #filePath says?")
        for (signature, file) in lookups.sorted(by: { $0.key.base < $1.key.base }) {
            #expect(catalog.contains(signature), "\(file) looks up \"\(signature)\", which \(module)'s catalog doesn't define")
        }
    }

    private static func catalogSignatures(at url: URL) throws -> Set<Signature> {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any])
        return Set(strings.keys.map { key in
            let parts = key.split(separator: " ")
            return Signature(base: String(parts.first ?? ""), arguments: parts.dropFirst().count { $0.hasPrefix("%") })
        })
    }

    /// Lookups in the module's Swift sources, with the file each came from.
    /// Only lookups that pass `bundle: #bundle` count: preview sample text is
    /// a bare literal and is never looked up.
    private static func lookupSignatures(under directory: URL) throws -> [Signature: String] {
        // The call, then its key literal, which may start on the next line
        let opening = try Regex(#"(?:LocalizedStringResource\(|String\(\s*localized:|Text\()\s*"((?:[^"\\\n]|\\.)*)""#)
        var found: [Signature: String] = [:]
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: opening) {
                guard let key = match.output[1].substring,
                      callPassesBundle(in: text[match.range.upperBound...])
                else { continue }
                // Only semantic keys ("area.thing"); a sentence used as its
                // own key predates the convention
                let base = key.prefix { $0 != " " }
                guard base.contains(".") else { continue }
                let arguments = key.components(separatedBy: "\\(").count - 1
                found[Signature(base: String(base), arguments: arguments)] = file.lastPathComponent
            }
        }
        return found
    }

    /// Whether the call whose key literal just ended passes `bundle: #bundle`
    /// before its closing parenthesis. Skips string literals so a comment
    /// argument's parentheses don't end the call early.
    private static func callPassesBundle(in rest: Substring) -> Bool {
        var depth = 1
        var inString = false
        var escaped = false
        var end = rest.startIndex
        for index in rest.indices {
            let character = rest[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
        }
        return rest[rest.startIndex ..< end].contains("bundle: #bundle")
    }
}

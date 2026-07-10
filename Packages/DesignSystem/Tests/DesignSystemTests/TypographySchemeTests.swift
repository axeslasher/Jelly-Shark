import Testing
import SwiftUI
@testable import DesignSystem

/// Guards for the theme typography scheme. The family-per-role `FontScheme`
/// initializer must seed every size/weight/tracking with the Standard scale
/// from `TypographyTokens` — that contract is what keeps Standard rendering
/// bit-identically while other themes hand-tune their own metrics.
@Suite("Typography Scheme Tests")
struct TypographySchemeTests {
    @Test("Family-init scheme carries the Standard scale for every role")
    func familyInitMatchesTokens() {
        let scheme = FontScheme(
            display: "A", headline: "B", title: "C", overview: "D",
            body: "E", caption: "F", small: "G"
        )

        let expected: [(TypeRole, CGFloat, Font.Weight)] = [
            (.display, TypographyTokens.Size.display, TypographyTokens.Weight.display),
            (.headline, TypographyTokens.Size.headline, TypographyTokens.Weight.headline),
            (.title, TypographyTokens.Size.title, TypographyTokens.Weight.title),
            (.overview, TypographyTokens.Size.overview, TypographyTokens.Weight.overview),
            (.body, TypographyTokens.Size.body, TypographyTokens.Weight.body),
            (.caption, TypographyTokens.Size.caption, TypographyTokens.Weight.caption),
            (.small, TypographyTokens.Size.small, TypographyTokens.Weight.small),
            (.eyebrow, TypographyTokens.Size.eyebrow, TypographyTokens.Weight.eyebrow),
            (.certificate, TypographyTokens.Size.certificate, TypographyTokens.Weight.certificate),
        ]
        for (role, size, weight) in expected {
            #expect(scheme[role].size == size, "\(role) size")
            #expect(scheme[role].weight == weight, "\(role) weight")
        }

        // Emphasis tiers default to the Standard mapping on every role
        for role in TypeRole.allCases {
            #expect(scheme[role].subtleWeight == .medium, "\(role) subtle")
            #expect(scheme[role].emphasizedWeight == .semibold, "\(role) emphasized")
            #expect(scheme[role].strongWeight == .bold, "\(role) strong")
        }

        // Tracking is zero everywhere except the wide-tracked eyebrow
        for role in TypeRole.allCases where role != .eyebrow {
            #expect(scheme[role].tracking == TypographyTokens.Tracking.normal, "\(role) tracking")
        }
        #expect(scheme.eyebrow.tracking == TypographyTokens.Tracking.wide)

        // Derived roles: eyebrow follows the caption family, certificate is Zodiak
        #expect(scheme.eyebrow.family == scheme.caption.family)
        #expect(scheme.certificate.family == FontFamily.zodiak)
    }

    @Test("Emphasis tiers resolve to the style's weights")
    func emphasisResolution() {
        var style = TypeStyle(size: 22, weight: .light)
        style.subtleWeight = .regular
        style.emphasizedWeight = .medium
        style.strongWeight = .heavy
        #expect(style.weight(for: .regular) == .light)
        #expect(style.weight(for: .subtle) == .regular)
        #expect(style.weight(for: .emphasized) == .medium)
        #expect(style.weight(for: .strong) == .heavy)
    }

    @Test("System scheme has no custom families outside the certificate badge")
    func systemScheme() {
        for role in TypeRole.allCases where role != .certificate {
            #expect(FontScheme.system[role].family == nil, "\(role)")
        }
        #expect(FontScheme.system.certificate.family == FontFamily.zodiak)
    }

    @Test("Standard theme stays on the token scale (bit-identity guard)")
    func standardThemePreserved() {
        let fonts = StandardTheme().fonts

        for role in [TypeRole.display, .headline, .title] {
            #expect(fonts[role].family == FontFamily.generalSans, "\(role)")
        }
        for role in [TypeRole.overview, .body, .caption, .small, .eyebrow] {
            #expect(fonts[role].family == FontFamily.satoshi, "\(role)")
        }
        #expect(fonts.certificate.family == FontFamily.zodiak)
        #expect(fonts.certificate.size == 18)
        #expect(fonts.certificate.weight == .bold)

        // Sizes and weights are exactly the Standard tokens — any drift here
        // is a visible change to the Standard theme
        for role in TypeRole.allCases {
            #expect(fonts[role].size == FontScheme.system[role].size, "\(role) size")
            #expect(fonts[role].weight == FontScheme.system[role].weight, "\(role) weight")
            #expect(fonts[role].tracking == FontScheme.system[role].tracking, "\(role) tracking")
        }
    }

    @Test("Certificates are Zodiak bold everywhere")
    func themeSchemeCuration() {
        // All themes currently share the Zodiak certificate badge; loosen
        // this once per-theme certificate curation diverges. Deliberately no
        // assertions on the other roles' curated values — those are in flux.
        for theme in ThemeCatalogTests.allThemes {
            let certificate = theme.fonts.certificate
            #expect(certificate.family == FontFamily.zodiak, "\(theme.id)")
            #expect(certificate.size == 18, "\(theme.id)")
            #expect(certificate.weight == .bold, "\(theme.id)")
        }
    }
}

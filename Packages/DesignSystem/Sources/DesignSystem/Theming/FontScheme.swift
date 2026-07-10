import SwiftUI
import CoreText

// MARK: - Font family names
//
// ┌──────────────────────────────────────────────────────────────────────────┐
// │ THIS IS WHERE YOU SWAP FONTS.                                              │
// │                                                                            │
// │ `FontFamily` holds the registered name `Font.custom(_:)` needs. These are  │
// │ best-guesses for the Fontshare variable files. If a font isn't applying,   │
// │ launch a DEBUG build and read the console — `registerAll()` prints every   │
// │ name the OS actually registered — then correct the strings below.          │
// │                                                                            │
// │ To change which typeface a role uses, edit the theme's `fonts` scheme      │
// │ (see `StandardTheme.fonts`), NOT the call sites. Every `.font(theme.jsTitle)`│
// │ etc. resolves through that view's theme environment automatically.         │
// └──────────────────────────────────────────────────────────────────────────┘
public enum FontFamily {
    // These are the registered FAMILY names (not filenames / PostScript names).
    // `Font.custom` resolves a variable font by family, and `.weight(_:)` then
    // selects the matching named instance. The upright and italic .ttf for each
    // family register under the SAME family name; italics are reached via the
    // SwiftUI `.italic()` modifier, not a separate name here.

    /// Geometric humanist sans — General Sans.
    public static let generalSans = "General Sans Variable"

    /// Contemporary serif — Zodiak.
    public static let zodiak = "Zodiak Variable"

    /// Geometric sans — Satoshi.
    public static let satoshi = "Satoshi Variable"

    /// Geometric/technical sans — Space Grotesk. (Upright only; no italic file.)
    public static let spaceGrotesk = "Space Grotesk Variable"

    /// High-legibility sans — Atkinson Hyperlegible Next (Braille Institute).
    /// OFL-licensed and committed to the repo. Intended for a future
    /// accessibility setting that swaps the whole UI to this face.
    public static let atkinson = "Atkinson Hyperlegible Next"

    /// High-contrast display serif — Bevellier.
    public static let bevellier = "Bevellier Variable"

    /// Sharp geometric display grotesk — Clash Grotesk. (Upright only.)
    public static let clashGrotesk = "Clash Grotesk Variable"

    /// Condensed wedge-serif — Grenze.
    public static let grenze = "Grenze"

    /// Blackletter display — Grenze Gotisch. (Upright only.)
    public static let grenzeGotisch = "Grenze Gotisch"

    /// Techy rounded sans — Nippo. (Upright only.)
    public static let nippo = "Nippo Variable"

    /// Condensed sans — Oswald. (Upright only.)
    public static let oswald = "Oswald"

    /// Friendly rounded sans — Pilcrow Rounded. (Upright only.)
    public static let pilcrowRounded = "Pilcrow Rounded Variable"

    /// Humanist old-style serif — Sentient.
    public static let sentient = "Sentient Variable"

    /// Workhorse neo-grotesque sans — Supreme.
    public static let supreme = "Supreme Variable"

    /// Swiss neo-grotesque sans — Switzer.
    public static let switzer = "Switzer Variable"

    /// Angular techno display sans — Technor. (Upright only.)
    public static let technor = "Technor Variable"
}

// MARK: - Type styles

/// One typographic role's full recipe — family, size, weight, emphasis
/// weights, and tracking. Every field is mutable so a theme can hand-tune any
/// role (different typefaces have different x-heights, and weights don't
/// transfer 1:1 between families).
public struct TypeStyle: Sendable {
    /// Registered font family name; `nil` means the system font (San
    /// Francisco), which is also the graceful fallback whenever the named
    /// font isn't installed.
    public var family: String?

    /// Point size (fixed; 10-foot UI does not scale with Dynamic Type).
    public var size: CGFloat

    /// Base weight for the role.
    public var weight: Font.Weight

    /// Weight for `.subtle` emphasis (Standard scale: medium).
    public var subtleWeight: Font.Weight

    /// Weight for `.emphasized` emphasis (Standard scale: semibold).
    public var emphasizedWeight: Font.Weight

    /// Weight for `.strong` emphasis (Standard scale: bold).
    public var strongWeight: Font.Weight

    /// Letter tracking for the role. `Font` can't carry tracking, so the
    /// `.jsStyle(_:_:)` view modifier applies it alongside the font — every
    /// themed-text call site goes through it, so tuning this renders
    /// everywhere the role appears.
    public var tracking: CGFloat

    public init(
        family: String? = nil,
        size: CGFloat,
        weight: Font.Weight = .regular,
        subtleWeight: Font.Weight = TypographyTokens.Weight.subtle,
        emphasizedWeight: Font.Weight = TypographyTokens.Weight.emphasized,
        strongWeight: Font.Weight = TypographyTokens.Weight.strong,
        tracking: CGFloat = TypographyTokens.Tracking.normal
    ) {
        self.family = family
        self.size = size
        self.weight = weight
        self.subtleWeight = subtleWeight
        self.emphasizedWeight = emphasizedWeight
        self.strongWeight = strongWeight
        self.tracking = tracking
    }
}

/// The typographic roles a theme styles. Call sites should use the
/// `.jsStyle(_:_:)` view modifier (font + tracking together), never
/// `Font.custom` directly.
public enum TypeRole: Sendable, CaseIterable {
    case display, headline, title, overview, body, caption, small, eyebrow, certificate
}

/// Semantic emphasis tiers components layer on a role instead of pinning
/// `.fontWeight(...)` themselves; each theme decides what a tier means per
/// role via `TypeStyle`'s `subtleWeight` / `emphasizedWeight` / `strongWeight`.
public enum TypeEmphasis: Sendable {
    case regular, subtle, emphasized, strong
}

extension TypeStyle {
    func weight(for emphasis: TypeEmphasis) -> Font.Weight {
        switch emphasis {
        case .regular: return weight
        case .subtle: return subtleWeight
        case .emphasized: return emphasizedWeight
        case .strong: return strongWeight
        }
    }

    /// Resolve the style into a `Font`, falling back to the system font when
    /// `family` is `nil` or unavailable. Custom resolution selects the
    /// variable font's weight axis via `.weight(_:)`.
    func font(_ emphasis: TypeEmphasis = .regular) -> Font {
        let resolvedWeight = weight(for: emphasis)
        guard let family else {
            return .system(size: size, weight: resolvedWeight)
        }
        return .custom(family, fixedSize: size).weight(resolvedWeight)
    }
}

// MARK: - Font scheme

/// Maps each typographic role to a full `TypeStyle`. The family-per-role
/// initializer seeds sizes, weights, and tracking with the Standard scale
/// from `TypographyTokens`, so a theme that only picks families renders on
/// the Standard metrics; hand-tune any role by mutating it afterward:
///
///     public let fonts: FontScheme = {
///         var scheme = FontScheme(display: FontFamily.nippo, ...)
///         scheme.display.weight = .black
///         scheme.display.size = 56
///         return scheme
///     }()
///
/// Build one of these per theme so each theme can have its own typography.
/// See `StandardTheme.fonts` for the worked example and swap instructions.
public struct FontScheme: Sendable {
    public var display: TypeStyle
    public var headline: TypeStyle
    public var title: TypeStyle
    public var overview: TypeStyle
    public var body: TypeStyle
    public var caption: TypeStyle
    public var small: TypeStyle
    public var eyebrow: TypeStyle
    public var certificate: TypeStyle

    /// Family-per-role initializer; everything else defaults to the Standard
    /// scale. `eyebrow` defaults to the caption family at eyebrow weight and
    /// wide tracking; `certificate` defaults to the Zodiak ratings badge.
    /// (Keep this the ONLY initializer — a second fully-defaulted init would
    /// make `FontScheme()` ambiguous.)
    public init(
        display: String? = nil,
        headline: String? = nil,
        title: String? = nil,
        overview: String? = nil,
        body: String? = nil,
        caption: String? = nil,
        small: String? = nil,
        eyebrow: TypeStyle? = nil,
        certificate: TypeStyle = TypeStyle(
            family: FontFamily.zodiak,
            size: TypographyTokens.Size.certificate,
            weight: TypographyTokens.Weight.certificate
        )
    ) {
        self.display = TypeStyle(
            family: display,
            size: TypographyTokens.Size.display,
            weight: TypographyTokens.Weight.display
        )
        self.headline = TypeStyle(
            family: headline,
            size: TypographyTokens.Size.headline,
            weight: TypographyTokens.Weight.headline
        )
        self.title = TypeStyle(
            family: title,
            size: TypographyTokens.Size.title,
            weight: TypographyTokens.Weight.title
        )
        self.overview = TypeStyle(
            family: overview,
            size: TypographyTokens.Size.overview,
            weight: TypographyTokens.Weight.overview
        )
        self.body = TypeStyle(
            family: body,
            size: TypographyTokens.Size.body,
            weight: TypographyTokens.Weight.body
        )
        self.caption = TypeStyle(
            family: caption,
            size: TypographyTokens.Size.caption,
            weight: TypographyTokens.Weight.caption
        )
        self.small = TypeStyle(
            family: small,
            size: TypographyTokens.Size.small,
            weight: TypographyTokens.Weight.small
        )
        self.eyebrow = eyebrow ?? TypeStyle(
            family: caption,
            size: TypographyTokens.Size.eyebrow,
            weight: TypographyTokens.Weight.eyebrow,
            tracking: TypographyTokens.Tracking.wide
        )
        self.certificate = certificate
    }

    /// All-system scheme: every role falls back to San Francisco (the
    /// certificate badge keeps its Zodiak default). This is the default for
    /// any theme that doesn't override `fonts`.
    public static let system = FontScheme()

    public subscript(role: TypeRole) -> TypeStyle {
        switch role {
        case .display: return display
        case .headline: return headline
        case .title: return title
        case .overview: return overview
        case .body: return body
        case .caption: return caption
        case .small: return small
        case .eyebrow: return eyebrow
        case .certificate: return certificate
        }
    }
}

// MARK: - Registration

/// Registers and inspects the bundled Fontshare fonts.
public enum DesignSystemFonts {
    /// Register every `.ttf` bundled in the module so `Font.custom(_:)` can find
    /// them. Safe to call repeatedly and safe when no fonts are present (a build
    /// without the downloaded binaries simply registers nothing and falls back
    /// to the system font).
    public static func registerAll() {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            // Errors here are non-fatal (e.g. already registered); ignore so a
            // re-register or a missing file never disrupts launch.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        #if DEBUG
        debugPrintRegisteredNames()
        #endif
    }

    #if DEBUG
    /// Print the family + PostScript names the OS registered for the bundled
    /// fonts, so you can confirm/correct the `FontFamily` constants.
    public static func debugPrintRegisteredNames() {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        guard !urls.isEmpty else {
            print("[DesignSystemFonts] No bundled .ttf found — using system font. See Resources/Fonts/FONTS.md.")
            return
        }
        for url in urls {
            // Family name is what `Font.custom(_:)` / `FontFamily` should use.
            let family = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?
                .first
                .flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
                ?? "?"
            let psName = CGDataProvider(url: url as CFURL)
                .flatMap { CGFont($0) }
                .flatMap { $0.postScriptName as String? }
                ?? "?"
            print("[DesignSystemFonts] \(url.lastPathComponent) → family: \"\(family)\"  postScript: \"\(psName)\"")
        }
    }
    #endif
}

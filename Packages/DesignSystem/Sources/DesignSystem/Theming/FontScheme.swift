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

// MARK: - Font scheme

/// Maps each typographic role to a registered font family name. A `nil` entry
/// means "use the system font (San Francisco)" for that role — which is also the
/// graceful fallback whenever the named font isn't installed.
///
/// Build one of these per theme so each theme can have its own typography. See
/// `StandardTheme.fonts` for the worked example and swap instructions.
public struct FontScheme: Sendable {
    public var display: String?
    public var headline: String?
    public var title: String?
    public var overview: String?
    public var body: String?
    public var caption: String?
    public var small: String?

    public init(
        display: String? = nil,
        headline: String? = nil,
        title: String? = nil,
        overview: String? = nil,
        body: String? = nil,
        caption: String? = nil,
        small: String? = nil
    ) {
        self.display = display
        self.headline = headline
        self.title = title
        self.overview = overview
        self.body = body
        self.caption = caption
        self.small = small
    }

    /// All-system scheme: every role falls back to San Francisco. This is the
    /// default for any theme that doesn't override `fonts`.
    public static let system = FontScheme()
}

extension FontScheme {
    /// Resolve a custom family name into a `Font` at the given size/weight,
    /// falling back to the system font when the name is `nil` or unavailable.
    /// Custom resolution uses the variable font's weight axis via `.weight(_:)`.
    func font(named name: String?, size: CGFloat, weight: Font.Weight) -> Font {
        guard let name else {
            return .system(size: size, weight: weight)
        }
        return .custom(name, fixedSize: size).weight(weight)
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

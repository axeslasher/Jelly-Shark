import Testing
import SwiftUI
@testable import DesignSystem

/// WCAG 2.x relative-luminance helpers built on `Color.resolve(in:)`.
/// `Color.Resolved`'s linear components are exactly the WCAG-linearized sRGB
/// channels; wide-gamut values can fall outside 0...1, so clamp before the
/// luminance sum.
private enum WCAG {
    static func luminance(_ color: Color, composedOver background: Color? = nil) -> Double {
        let resolved = color.resolve(in: EnvironmentValues())
        var (r, g, b) = (
            Double(resolved.linearRed),
            Double(resolved.linearGreen),
            Double(resolved.linearBlue)
        )
        if let background, resolved.opacity < 1 {
            let bg = background.resolve(in: EnvironmentValues())
            let alpha = Double(resolved.opacity)
            r = r * alpha + Double(bg.linearRed) * (1 - alpha)
            g = g * alpha + Double(bg.linearGreen) * (1 - alpha)
            b = b * alpha + Double(bg.linearBlue) * (1 - alpha)
        }
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        return 0.2126 * clamp(r) + 0.7152 * clamp(g) + 0.0722 * clamp(b)
    }

    static func contrastRatio(_ foreground: Color, on background: Color) -> Double {
        let fg = luminance(foreground, composedOver: background)
        let bg = luminance(background)
        return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
    }
}

@Suite("Theme Catalog Tests")
struct ThemeCatalogTests {
    static let allThemes: [any Theme] = [
        StandardTheme(), HorrorTheme(), ActionTheme(), VideoStoreTheme(),
    ]

    @Suite("OKLCH Conversion")
    struct OKLCHConversionTests {
        @Test("Achromatic endpoints resolve to white and black")
        func achromaticEndpoints() {
            let white = Color(oklch: 1, 0, 0).resolve(in: EnvironmentValues())
            let black = Color(oklch: 0, 0, 0).resolve(in: EnvironmentValues())
            for channel in [white.linearRed, white.linearGreen, white.linearBlue] {
                #expect(abs(channel - 1) < 0.001)
            }
            for channel in [black.linearRed, black.linearGreen, black.linearBlue] {
                #expect(abs(channel) < 0.001)
            }
        }

        @Test("Mid gray is neutral with the expected linear value")
        func midGray() {
            // oklch(0.5 0 0): LMS' = 0.5, cubed = 0.125; the sRGB matrix rows
            // each sum to 1, so every linear channel is exactly 0.125
            let gray = Color(oklch: 0.5, 0, 0).resolve(in: EnvironmentValues())
            #expect(abs(Double(gray.linearRed) - 0.125) < 0.001)
            #expect(abs(Double(gray.linearRed - gray.linearGreen)) < 0.001)
            #expect(abs(Double(gray.linearGreen - gray.linearBlue)) < 0.001)
        }

        @Test("Chroma lands in the right hue and lightness stays ordered")
        func hueAndLightness() {
            // red500 should be red-dominant
            let red = BaseColors.red500.resolve(in: EnvironmentValues())
            #expect(red.linearRed > red.linearGreen)
            #expect(red.linearRed > red.linearBlue)

            // Luminance must fall monotonically across a family's shades
            let reds = [
                BaseColors.red100, BaseColors.red300, BaseColors.red500,
                BaseColors.red700, BaseColors.red900,
            ]
            let luminances = reds.map { WCAG.luminance($0) }
            #expect(luminances == luminances.sorted(by: >))
        }
    }

    @Suite("Theme Identity")
    struct ThemeIdentityTests {
        @Test("Theme ids match their ThemeIdentifier raw values")
        func idsMatchIdentifiers() {
            #expect(StandardTheme().id == ThemeIdentifier.standard.rawValue)
            #expect(HorrorTheme().id == ThemeIdentifier.horror.rawValue)
            #expect(ActionTheme().id == ThemeIdentifier.action.rawValue)
            #expect(VideoStoreTheme().id == ThemeIdentifier.videoStore.rawValue)
        }

        @Test("Theme names match identifier display names")
        func namesMatchDisplayNames() {
            #expect(StandardTheme().name == ThemeIdentifier.standard.displayName)
            #expect(HorrorTheme().name == ThemeIdentifier.horror.displayName)
            #expect(ActionTheme().name == ThemeIdentifier.action.displayName)
            #expect(VideoStoreTheme().name == ThemeIdentifier.videoStore.displayName)
        }

        @Test("Every theme has a description")
        func descriptionsPresent() {
            for theme in ThemeCatalogTests.allThemes {
                #expect(!theme.description.isEmpty, "\(theme.id)")
            }
        }

        @MainActor
        @Test("ThemeManager resolves each identifier to its own theme")
        func managerWiring() {
            #expect(ThemeManager.shared.theme(for: .standard) is StandardTheme)
            #expect(ThemeManager.shared.theme(for: .horror) is HorrorTheme)
            #expect(ThemeManager.shared.theme(for: .action) is ActionTheme)
            #expect(ThemeManager.shared.theme(for: .videoStore) is VideoStoreTheme)
        }
    }

    @Suite("Palette Distinctness")
    struct PaletteDistinctnessTests {
        @Test("Backgrounds differ across all themes")
        func distinctBackgrounds() {
            let resolved = ThemeCatalogTests.allThemes.map {
                $0.background.resolve(in: EnvironmentValues())
            }
            #expect(Set(resolved).count == ThemeCatalogTests.allThemes.count)
        }

        @Test("Accents differ across all themes")
        func distinctAccents() {
            let resolved = ThemeCatalogTests.allThemes.map {
                $0.accent.resolve(in: EnvironmentValues())
            }
            #expect(Set(resolved).count == ThemeCatalogTests.allThemes.count)
        }
    }

    @Suite("WCAG Contrast")
    struct ContrastTests {
        @Test("Text colors meet AA (4.5:1) on background and surface")
        func textContrast() {
            for theme in ThemeCatalogTests.allThemes {
                for (label, text) in [
                    ("primary", theme.primary),
                    ("secondary", theme.secondary),
                    ("tertiary", theme.tertiary),
                ] {
                    let onBackground = WCAG.contrastRatio(text, on: theme.background)
                    let onSurface = WCAG.contrastRatio(text, on: theme.surface)
                    #expect(onBackground >= 4.5, "\(theme.id) \(label)/background: \(onBackground)")
                    #expect(onSurface >= 4.5, "\(theme.id) \(label)/surface: \(onSurface)")
                }
                let onElevated = WCAG.contrastRatio(theme.primary, on: theme.surfaceElevated)
                #expect(onElevated >= 4.5, "\(theme.id) primary/surfaceElevated: \(onElevated)")
            }
        }

        @Test("Accents meet non-text contrast (3:1) on background and surface")
        func accentContrast() {
            for theme in ThemeCatalogTests.allThemes {
                let onBackground = WCAG.contrastRatio(theme.accent, on: theme.background)
                let onSurface = WCAG.contrastRatio(theme.accent, on: theme.surface)
                #expect(onBackground >= 3.0, "\(theme.id) accent/background: \(onBackground)")
                #expect(onSurface >= 3.0, "\(theme.id) accent/surface: \(onSurface)")
            }
        }

        @Test("Themed focus platters stand out and keep their content legible")
        func focusFillContrast() {
            for theme in ThemeCatalogTests.allThemes {
                guard let focusFill = theme.focusFill else { continue }
                let content = WCAG.contrastRatio(theme.onFocusFill, on: focusFill)
                let secondary = WCAG.contrastRatio(theme.onFocusFillSecondary, on: focusFill)
                let lift = WCAG.contrastRatio(focusFill, on: theme.background)
                #expect(content >= 4.5, "\(theme.id) onFocusFill/focusFill: \(content)")
                #expect(secondary >= 4.5, "\(theme.id) onFocusFillSecondary/focusFill: \(secondary)")
                #expect(lift >= 3.0, "\(theme.id) focusFill/background: \(lift)")
            }
        }

        @Test("Focus rings meet indicator contrast (3:1) on background and surface")
        func focusRingContrast() {
            for theme in ThemeCatalogTests.allThemes {
                let onBackground = WCAG.contrastRatio(theme.focusRing, on: theme.background)
                let onSurface = WCAG.contrastRatio(theme.focusRing, on: theme.surface)
                #expect(onBackground >= 3.0, "\(theme.id) focusRing/background: \(onBackground)")
                #expect(onSurface >= 3.0, "\(theme.id) focusRing/surface: \(onSurface)")
            }
        }
    }

    @Suite("Motion")
    struct MotionDistinctnessTests {
        @Test("Transition durations are theme-specific")
        func distinctDurations() {
            let durations = ThemeCatalogTests.allThemes.map(\.transitionDuration)
            #expect(Set(durations).count == ThemeCatalogTests.allThemes.count)
        }
    }
}

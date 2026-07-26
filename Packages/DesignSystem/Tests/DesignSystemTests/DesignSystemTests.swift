// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@testable import DesignSystem
import SwiftUI
import Testing

@Suite("DesignSystem Tests")
struct DesignSystemTests {
    @Suite("Theme Tests")
    struct ThemeTests {
        @Test("StandardTheme has correct identity")
        func standardThemeIdentity() {
            let theme = StandardTheme()
            #expect(theme.id == "standard")
            #expect(theme.name == "Standard")
        }

        @Test("StandardTheme colors are set")
        func standardThemeColors() {
            let theme = StandardTheme()
            // Just verify colors exist and are accessible
            _ = theme.background
            _ = theme.surface
            _ = theme.primary
            _ = theme.accent
        }

        @Test("Theme default values")
        func themeDefaults() {
            let theme = StandardTheme()
            #expect(theme.spacingUnit == SpacingTokens.unit)
            #expect(theme.cardPadding == SpacingTokens.cardPadding)
            #expect(theme.focusScale == MotionTokens.focusScale)
        }
    }

    @Suite("Spacing Tokens")
    struct SpacingTests {
        @Test("Spacing scale is consistent")
        func spacingScale() {
            #expect(SpacingTokens.xs < SpacingTokens.sm)
            #expect(SpacingTokens.sm < SpacingTokens.md)
            #expect(SpacingTokens.md < SpacingTokens.lg)
            #expect(SpacingTokens.lg < SpacingTokens.xl)
        }

        @Test("Base unit is 8pt")
        func baseUnit() {
            #expect(SpacingTokens.unit == 8)
        }
    }

    @Suite("Typography Tokens")
    struct TypographyTests {
        @Test("Font sizes are ordered")
        func fontSizeOrder() {
            #expect(TypographyTokens.Size.small < TypographyTokens.Size.caption)
            #expect(TypographyTokens.Size.caption < TypographyTokens.Size.body)
            #expect(TypographyTokens.Size.body < TypographyTokens.Size.title)
            #expect(TypographyTokens.Size.title < TypographyTokens.Size.headline)
            #expect(TypographyTokens.Size.headline < TypographyTokens.Size.display)
        }
    }

    @Suite("Motion Tokens")
    struct MotionTests {
        @Test("Duration ordering")
        func durationOrder() {
            #expect(MotionTokens.durationFast < MotionTokens.durationNormal)
            #expect(MotionTokens.durationNormal < MotionTokens.durationSlow)
        }

        @Test("Focus scale is reasonable")
        func focusScale() {
            #expect(MotionTokens.focusScale > 1.0)
            #expect(MotionTokens.focusScale < 1.2)
        }
    }

    @Suite("Color Tokens")
    struct ColorTests {
        @Test("Color hex initialization")
        func colorHex() {
            let white = Color(hex: "FFFFFF")
            let black = Color(hex: "000000")
            // Colors are created without crashing
            _ = white
            _ = black
        }
    }

    @Suite("Theme Identifier")
    struct ThemeIdentifierTests {
        @Test("All themes have display names")
        func displayNames() {
            for theme in ThemeIdentifier.allCases {
                #expect(!theme.displayName.isEmpty)
            }
        }

        @Test("Theme count")
        func themeCount() {
            #expect(ThemeIdentifier.allCases.count == 5)
        }
    }
}

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

import SwiftUI

/// The Video Store theme - 90s rental-store nostalgia in deep blue and gold
/// Colors are first-pass BaseColors picks pending hand curation; each choice
/// must keep the WCAG floors enforced by ThemeCatalogTests.
public struct VideoStoreTheme: Theme, Sendable {
    // MARK: - Identity

    public let id = "videoStore"
    public let name = "Video Store"
    public let description = "90s nostalgia, Friday night vibes. Bouncy, playful motion in deep blue and gold."

    // MARK: - Colors

    public let background = BaseColors.blue950
    public let surface = BaseColors.blue900
    public let surfaceElevated = BaseColors.blue800
    public let primary = BaseColors.yellow100
    public let secondary = BaseColors.yellow100.opacity(0.9)
    public let tertiary = BaseColors.yellow300.opacity(0.8)
    public let onPlatter = BaseColors.blue950
    public let onPlatterSecondary = BaseColors.blue700
    public let accent = BaseColors.yellow400
    public let accentSecondary = BaseColors.blue400
    public let success = BaseColors.lime500
    public let warning = BaseColors.orange400
    public let error = BaseColors.red400
    public let focusRing = BaseColors.yellow400.opacity(0.8)
    public let focusFill: Color? = BaseColors.blue600.opacity(0.6)
    public let onFocusFill = BaseColors.yellow200
    public let onFocusFillSecondary = BaseColors.yellow300

    // MARK: - Typography

    public let fonts: FontScheme = {
        var scheme = FontScheme(
            display: FontFamily.nippo,
            headline: FontFamily.nippo,
            title: FontFamily.generalSans,
            overview: FontFamily.supreme,
            body: FontFamily.supreme,
            caption: FontFamily.supreme,
            small: FontFamily.supreme,
            certificate: TypeStyle(
                family: FontFamily.zodiak,
                size: TypographyTokens.Size.certificate,
                weight: TypographyTokens.Weight.certificate,
            ),
        )
        scheme.display.weight = .heavy
        scheme.display.size = TypographyTokens.Size.display * 1.4
        scheme.display.tracking = TypographyTokens.Tracking.wide
        scheme.headline.weight = .heavy
        scheme.headline.size = TypographyTokens.Size.headline * 1.2
        scheme.headline.tracking = TypographyTokens.Tracking.wide
        return scheme
    }()

    // MARK: - Motion

    public let transitionDuration: TimeInterval = 0.35
    public let animation: Animation = MotionTokens.videoStoreAnimation

    // MARK: - Initialization

    public init() {}
}

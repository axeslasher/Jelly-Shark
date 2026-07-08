import SwiftUI

public extension Color {
    /// Initialize a Color from OKLCH components (the CSS `oklch()` notation).
    ///
    /// Converts OKLCH → OKLab → linear sRGB using Björn Ottosson's reference
    /// matrices. Components are intentionally left unclamped and handed to the
    /// extended linear sRGB color space, so wide-gamut shades (chroma outside
    /// the sRGB gamut) render faithfully on P3/HDR-capable displays instead of
    /// being clipped.
    ///
    /// - Parameters:
    ///   - lightness: Perceptual lightness, `0...1` (CSS percentage ÷ 100)
    ///   - chroma: Chroma (0 is achromatic; Tailwind tops out around 0.37)
    ///   - hue: Hue angle in degrees
    ///   - opacity: Alpha, `0...1`
    init(oklch lightness: Double, _ chroma: Double, _ hue: Double, opacity: Double = 1) {
        let hueRadians = hue * .pi / 180
        let a = chroma * cos(hueRadians)
        let b = chroma * sin(hueRadians)

        // OKLab → non-linear LMS
        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * b

        // Cube to linear LMS
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        // Linear LMS → linear sRGB
        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        self.init(.sRGBLinear, red: red, green: green, blue: blue, opacity: opacity)
    }
}

import Foundation
import SwiftUI

/// A focusable 16:9 genre card for use inside a ``ContentShelf`` or grid.
///
/// The background is a set of soft radial color blobs drawn from the active
/// theme's palette, so every theme produces its own genre wash. A stable hash of
/// the genre name varies the blobs per card (color rotation + positions), and
/// while the card is focused the blobs gently drift — the repo's one time-driven
/// animation, scoped to the focused card so idle cards stay static. When a
/// backdrop URL is supplied it's laid over the blobs as a **grayscale** image at
/// reduced opacity.
///
/// Like ``ArtworkShelfItem``, navigation is value-based: the card appends
/// `value` to the enclosing `NavigationStack`'s path and the stack's
/// `navigationDestination(for:)` resolves the screen, keeping the component free
/// of feature/model dependencies.
public struct GenreShelfItem<Value: Hashable>: View {
    private let title: String
    private let backdropURL: URL?
    private let blurHash: String?
    private let width: CGFloat
    private let value: Value

    // TODO(#21): expose the blob-styling knobs as init params (defaulted) so call
    // sites can tune them without editing the component — blob count, drift
    // amount, blend mode (GenreGradientVariation), and the backdrop grayscale /
    // opacity (GenreCardContent) are hard-coded for now.
    public init(
        title: String,
        backdropURL: URL? = nil,
        blurHash: String? = nil,
        width: CGFloat = 664,
        value: Value,
    ) {
        self.title = title
        self.backdropURL = backdropURL
        self.blurHash = blurHash
        self.width = width
        self.value = value
    }

    public var body: some View {
        NavigationLink(value: value) {
            // The card content is its own view so it can read `\.isFocused` —
            // that flag only resolves inside the NavigationLink's focusable
            // label subtree, not on the view that owns the link.
            GenreCardContent(title: title, backdropURL: backdropURL, blurHash: blurHash, width: width)
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Card content

private struct GenreCardContent: View {
    let title: String
    let backdropURL: URL?
    let blurHash: String?
    let width: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Time the card gained focus, so the drift starts at zero on focus-in
    /// (offsets are `sin(phase)`, so blobs ease out from rest with no pop). `nil`
    /// while unfocused, which also gates the `TimelineView` to the focused card.
    @State private var focusStart: Date?

    /// Deterministic per-genre blob recipe, computed once from the title — not
    /// per animation frame.
    private let variation: GenreGradientVariation

    init(title: String, backdropURL: URL?, blurHash: String?, width: CGFloat) {
        self.title = title
        self.backdropURL = backdropURL
        self.blurHash = blurHash
        self.width = width
        variation = GenreGradientVariation(seed: Self.stableSeed(title))
    }

    private var height: CGFloat {
        (width * 9.0 / 16.0).rounded()
    }

    private var diagonal: CGFloat {
        (width * width + height * height).squareRoot()
    }

    /// Gentle base rate scaled by the theme's transition duration, so Horror
    /// drifts slower and Action faster (radians/second).
    private var driftSpeed: Double {
        0.8 * MotionTokens.durationNormal / theme.transitionDuration
    }

    var body: some View {
        ZStack {
            gradientBackground

            // Grayscale backdrop at reduced opacity so the blobs show through
            // (nil URL renders the wash alone).
            if backdropURL != nil {
                ArtworkImage(url: backdropURL, blurHash: blurHash, contentMode: .fill)
                    .grayscale(1)
                    .opacity(0.35)
            }

            // No scrim: the display weight and `primary` color read cleanly over
            // the wash at 10 feet.
            Text(title)
                .jsStyle(.display)
                .foregroundStyle(theme.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(SpacingTokens.md)
        }
        .frame(width: width, height: height)
        .artworkCornerRadius(theme.cornerRadius)
        // Lift, specular highlight, and gimbal motion on focus.
        .hoverEffect(.highlight)
        .onChange(of: isFocused) { _, focused in
            focusStart = focused ? Date() : nil
        }
    }

    @ViewBuilder
    private var gradientBackground: some View {
        if let focusStart, !reduceMotion {
            // Only the focused card ticks. `context.date` advances the drift;
            // offsets are zero at focus-in and grow smoothly. Reduce Motion skips
            // the TimelineView entirely and holds the static wash.
            TimelineView(.animation) { context in
                blobs(elapsed: context.date.timeIntervalSince(focusStart))
            }
        } else {
            blobs(elapsed: 0)
        }
    }

    /// Layered soft radial blobs over the theme's darkest wash color. `.screen`
    /// blending lets overlapping blobs add into a glow (like the reference
    /// mesh-blob shader) without warping the card's edges.
    private func blobs(elapsed: Double) -> some View {
        ZStack {
            theme.surfaceElevated

            ForEach(variation.blobs.indices, id: \.self) { index in
                let blob = variation.blobs[index]
                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [variation.color(for: blob, theme: theme), .clear],
                            center: variation.center(for: blob, elapsed: elapsed, speed: driftSpeed),
                            startRadius: 0,
                            endRadius: blob.radiusFactor * diagonal,
                        ),
                    )
                    .blendMode(.hardLight)
            }
        }
        // Isolate the blend so the glow composites against the card wash only,
        // never the app background behind the card.
        .compositingGroup()
    }

    /// FNV-1a over the genre name. `String.hashValue` is per-process randomized,
    /// so a card would look different every launch — this is stable.
    private static func stableSeed(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Gradient variation

/// A deterministic set of radial blobs derived from a genre's seed: each blob has
/// a base position, a palette color, a radius, and per-axis drift frequencies.
/// The color assignment is rotated per genre so no two cards in a shelf match.
private struct GenreGradientVariation {
    struct Blob {
        let basePosition: SIMD2<Double>
        let colorIndex: Int
        let radiusFactor: CGFloat
        let freq: SIMD2<Double>
    }

    /// Blob palette in brightness order (the darkest, `surfaceElevated`, is the
    /// wash the blobs sit on, not a blob color).
    private static let paletteCount = 3
    private static let blobCount = 5

    /// Drift radius, in UV space, of a focused blob's orbit.
    private static let driftAmount = 0.33

    let blobs: [Blob]
    private let rotation: Int

    init(seed: UInt64) {
        var rng = SeededRNG(state: seed)
        rotation = Int(rng.next() % UInt64(Self.paletteCount))

        var blobs: [Blob] = []
        for index in 0 ..< Self.blobCount {
            blobs.append(
                Blob(
                    // Spread around the card, biased away from dead-center.
                    basePosition: [0.5 + rng.signedUnit() * 0.32, 0.5 + rng.signedUnit() * 0.32],
                    colorIndex: (index + rotation) % Self.paletteCount,
                    radiusFactor: CGFloat(0.45 + rng.unit() * 0.35),
                    freq: [0.6 + rng.unit() * 1, 0.6 + rng.unit() * 1],
                ),
            )
        }
        self.blobs = blobs
    }

    /// A blob's center at a given time: its base position plus a `sin`-based
    /// drift that is zero at `elapsed == 0` (so focus-in doesn't pop).
    func center(for blob: Blob, elapsed: Double, speed: Double) -> UnitPoint {
        let phase = elapsed * speed
        let x = blob.basePosition.x + Self.driftAmount * sin(phase * blob.freq.x)
        let y = blob.basePosition.y + Self.driftAmount * sin(phase * blob.freq.y)
        return UnitPoint(x: x, y: y)
    }

    func color(for blob: Blob, theme: any Theme) -> Color {
        // Brightness order: accent (brightest) → accentSecondary → tertiary.
        let palette = [theme.accent, theme.accentSecondary, theme.tertiary]
        return palette[blob.colorIndex]
    }
}

/// SplitMix64 — a tiny deterministic PRNG so a genre's seed yields a stable
/// sequence of blob positions/frequencies.
private struct SeededRNG {
    var state: UInt64

    init(state: UInt64) {
        self.state = state == 0 ? 0x9E37_79B9_7F4A_7C15 : state
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0.0 ..< 1.0`.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / Double(1 << 53))
    }

    /// A value in `-1.0 ..< 1.0`.
    mutating func signedUnit() -> Double {
        unit() * 2 - 1
    }
}

#Preview {
    HStack(spacing: SpacingTokens.cardGap) {
        GenreShelfItem(title: "Horror", value: "horror")
        GenreShelfItem(title: "Science Fiction", value: "scifi")
    }
    .padding()
    .withThemeEnvironment()
}

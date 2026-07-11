import SwiftUI

/// A focusable 16:9 genre card for use inside a ``ContentShelf`` or grid.
///
/// The background is a ``MeshGradient`` woven from the active theme's colors, so
/// every theme produces its own genre palette. When a backdrop URL is supplied
/// it's laid over the mesh as a **grayscale** image at reduced opacity — the
/// mesh reads through it — with a legibility scrim under the centered label.
///
/// Like ``ArtworkShelfItem``, navigation is value-based: the card appends
/// `value` to the enclosing `NavigationStack`'s path and the stack's
/// `navigationDestination(for:)` resolves the screen, keeping the component free
/// of feature/model dependencies. The `.highlight` hover effect is attached to
/// the whole card so it lifts as one on focus.
public struct GenreShelfItem<Value: Hashable>: View {
    private let title: String
    private let backdropURL: URL?
    private let blurHash: String?
    private let width: CGFloat
    private let value: Value

    @Environment(\.theme) private var theme

    public init(
        title: String,
        backdropURL: URL? = nil,
        blurHash: String? = nil,
        width: CGFloat = 360,
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
            card
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var card: some View {
        ZStack {
            mesh

            // Grayscale backdrop at reduced opacity so the mesh shows through
            // (nil URL renders the mesh alone). Composited over, not blended,
            // per the issue's "grayscale, reduced opacity" spec.
            if backdropURL != nil {
                ArtworkImage(url: backdropURL, blurHash: blurHash, contentMode: .fill)
                    .grayscale(1)
                    .opacity(0.35)
            }

            // Keeps the label legible over both bright mesh stops and arbitrary
            // artwork.
            LinearGradient(
                colors: [theme.background.opacity(0.55), .clear],
                startPoint: .bottom,
                endPoint: .center,
            )

            Text(title)
                .jsStyle(.headline)
                .foregroundStyle(theme.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(SpacingTokens.md)
        }
        .frame(width: width, height: (width * 9.0 / 16.0).rounded())
        .artworkCornerRadius(theme.cornerRadius)
        // Lift, specular highlight, and gimbal motion on focus.
        .hoverEffect(.highlight)
    }

    /// A diagonal wash from `accent` (top-leading) toward `background`
    /// (bottom-trailing), with `accentSecondary` and the surface tones threaded
    /// through the middle for depth. Each theme's tokens re-tint it.
    private var mesh: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                theme.accent, theme.accentSecondary, theme.surfaceElevated,
                theme.accentSecondary, theme.surface, theme.background,
                theme.surface, theme.background, theme.background,
            ],
        )
    }
}

#Preview {
    HStack(spacing: SpacingTokens.lg) {
        GenreShelfItem(title: "Horror", value: "horror")
        GenreShelfItem(title: "Science Fiction", value: "scifi")
    }
    .padding()
    .withThemeEnvironment()
}

import SwiftUI

/// A themed view for remote artwork (posters, backdrops, thumbnails)
///
/// Renders the image over a surface-colored base, showing a centered SF Symbol
/// while loading, on failure, or when no URL is available. The surface base is
/// greedy, so the artwork is always cropped to the size the caller proposes even
/// when a fallback image has a different aspect ratio than its slot. The component
/// never drives layout: callers size it with `.frame` or `.aspectRatio` and round
/// it with the `cornerRadius` parameter (or `.clipShape`).
public struct ArtworkImage: View {
    let url: URL?
    let placeholderIcon: String
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    @Environment(\.theme) private var theme

    public init(
        url: URL?,
        placeholderIcon: String = "photo",
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 0
    ) {
        self.url = url
        self.placeholderIcon = placeholderIcon
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        // A greedy surface base takes the exact size the caller proposes, so the
        // image (laid on top and filled) is always cropped to the card's box —
        // even when a fallback image has a different aspect ratio than the slot.
        theme.surface
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: contentMode)
                        case .empty, .failure:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .artworkCornerRadius(cornerRadius)
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: placeholderIcon)
            .font(.system(size: 32))
            .foregroundStyle(theme.tertiary)
    }
}

public extension View {
    /// Clips a view to a continuous rounded rectangle. A radius of `0` produces
    /// the same square-cornered clip as `.clipped()`.
    func artworkCornerRadius(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

#Preview {
    HStack(spacing: SpacingTokens.lg) {
        ArtworkImage(url: nil, placeholderIcon: "film.fill")
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))

        ArtworkImage(url: nil)
            .frame(width: 320, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .withThemeEnvironment()
}

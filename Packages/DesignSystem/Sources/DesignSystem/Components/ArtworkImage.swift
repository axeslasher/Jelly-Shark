import SwiftUI

/// A themed view for remote artwork (posters, backdrops, thumbnails)
///
/// Renders the image over a surface-colored base. While loading (and on
/// failure) it shows the item's decoded blurhash when one is provided — a
/// color-accurate preview of the incoming artwork — otherwise a centered SF
/// Symbol. The surface base is greedy, so the artwork is always cropped to the
/// size the caller proposes even when a fallback image has a different aspect
/// ratio than its slot. The component never drives layout: callers size it
/// with `.frame` or `.aspectRatio` and round it with the `cornerRadius`
/// parameter (or `.clipShape`).
public struct ArtworkImage: View {
    let url: URL?
    let blurHash: String?
    let placeholderIcon: String
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    @Environment(\.theme) private var theme

    /// Decoded blurhash placeholder; decoding happens off the main actor in
    /// the view's task and usually beats the network image comfortably.
    @State private var blurPlaceholder: CGImage?

    public init(
        url: URL?,
        blurHash: String? = nil,
        placeholderIcon: String = "photo",
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 0
    ) {
        self.url = url
        self.blurHash = blurHash
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
            .task(id: blurHash) {
                guard let blurHash else {
                    blurPlaceholder = nil
                    return
                }
                blurPlaceholder = await decodeBlurHash(blurHash)
            }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let blurPlaceholder {
            Image(decorative: blurPlaceholder, scale: 1)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Image(systemName: placeholderIcon)
                .font(.system(size: 32))
                .foregroundStyle(theme.tertiary)
        }
    }
}

/// Hop off the main actor for the decode — it's pure math, and shelves mount
/// many cards at once.
private func decodeBlurHash(_ hash: String) async -> CGImage? {
    BlurHash.decode(hash)
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

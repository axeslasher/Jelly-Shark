import SwiftUI

/// A themed view for remote artwork (posters, backdrops, thumbnails)
///
/// Renders the image over a surface-colored base, showing a centered SF Symbol
/// while loading, on failure, or when no URL is available. The component never
/// drives layout: callers size it with `.frame` or `.aspectRatio` and round it
/// with `.clipShape`.
public struct ArtworkImage: View {
    let url: URL?
    let placeholderIcon: String
    let contentMode: ContentMode

    @Environment(\.theme) private var theme

    public init(
        url: URL?,
        placeholderIcon: String = "photo",
        contentMode: ContentMode = .fill
    ) {
        self.url = url
        self.placeholderIcon = placeholderIcon
        self.contentMode = contentMode
    }

    public var body: some View {
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
            .clipped()
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: placeholderIcon)
            .font(.system(size: 32))
            .foregroundStyle(theme.tertiary)
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

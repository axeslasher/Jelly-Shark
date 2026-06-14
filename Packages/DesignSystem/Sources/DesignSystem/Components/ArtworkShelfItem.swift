import SwiftUI

/// A focusable artwork card for use inside a ``ContentShelf`` or grid.
///
/// Produces the standard tvOS "lockup": the artwork and its two caption lines are
/// **direct children** of the `NavigationLink` label (never wrapped together in a
/// stack), which is what lets `.borderless` move the caption out of the way as the
/// artwork lifts on focus.
///
/// The `.highlight` hover effect is attached explicitly to the whole artwork. The
/// borderless style otherwise lifts the *first `Image` it finds* in the label, and
/// since the real image is an `AsyncImage` nested below `ArtworkImage`'s clip, the
/// default behavior scales that inner image inside the fixed, clipped frame — the
/// "image grows inside its container" bug. Attaching the effect to the card makes
/// the whole artwork lift instead.
///
/// The destination is supplied by the caller so this component stays free of any
/// feature/model dependencies.
public struct ArtworkShelfItem<Destination: View>: View {
    private let url: URL?
    private let title: String
    private let subtitle: String?
    private let placeholderIcon: String
    private let aspectRatio: CGFloat
    private let width: CGFloat
    private let progress: Double?
    private let destination: Destination

    @Environment(\.theme) private var theme

    public init(
        url: URL?,
        title: String,
        subtitle: String? = nil,
        placeholderIcon: String = "film.fill",
        aspectRatio: CGFloat = 2.0 / 3.0,
        width: CGFloat = 200,
        progress: Double? = nil,
        @ViewBuilder destination: () -> Destination
    ) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.placeholderIcon = placeholderIcon
        self.aspectRatio = aspectRatio
        self.width = width
        self.progress = progress
        self.destination = destination()
    }

    public var body: some View {
        NavigationLink {
            destination
        } label: {
            // Artwork and caption are intentionally siblings, not nested in a
            // VStack — see the type doc for why.
            ArtworkImage(url: url, placeholderIcon: placeholderIcon)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(width: width)
                .overlay(alignment: .bottomLeading) {
                    if let progress {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: width * progress, height: 4)
                    }
                }
                .artworkCornerRadius(theme.cornerRadius)
                .artworkHighlightOnFocus()

            Text(title)
                .font(.jsCaption)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .frame(width: width)

            // Reserve the second line even when empty so cards with one vs. two
            // caption lines stay aligned across a row.
            Text(subtitle ?? " ")
                .font(.jsCaption)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(width: width)
                .opacity(subtitle == nil ? 0 : 1)
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

private extension View {
    /// Attaches the `.highlight` hover effect (lift, specular highlight, gimbal
    /// motion on focus) where the platform supports it. `hoverEffect` is
    /// unavailable on macOS, which the package builds for to run tests.
    @ViewBuilder
    func artworkHighlightOnFocus() -> some View {
        #if os(tvOS) || os(visionOS) || os(iOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

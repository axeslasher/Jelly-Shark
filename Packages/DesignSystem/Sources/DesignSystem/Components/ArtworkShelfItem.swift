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
/// Navigation is value-based: the card appends `value` to the enclosing
/// `NavigationStack`'s path, and the stack's `navigationDestination(for:)`
/// resolves the screen. This keeps the component free of feature/model
/// dependencies and — unlike a view-destination link — lets the app pop the
/// stack programmatically (used to work around a tvOS `sidebarAdaptable` bug
/// where switching tabs with a pushed view strands the pushed screen).
public struct ArtworkShelfItem<Value: Hashable>: View {
    private let url: URL?
    private let blurHash: String?
    private let title: String
    private let subtitle: String?
    private let placeholderIcon: String
    private let aspectRatio: CGFloat
    private let width: CGFloat
    private let progress: Double?
    private let value: Value

    @Environment(\.theme) private var theme

    public init(
        url: URL?,
        blurHash: String? = nil,
        title: String,
        subtitle: String? = nil,
        placeholderIcon: String = "film.fill",
        aspectRatio: CGFloat = 2.0 / 3.0,
        width: CGFloat = 200,
        progress: Double? = nil,
        value: Value
    ) {
        self.url = url
        self.blurHash = blurHash
        self.title = title
        self.subtitle = subtitle
        self.placeholderIcon = placeholderIcon
        self.aspectRatio = aspectRatio
        self.width = width
        self.progress = progress
        self.value = value
    }

    public var body: some View {
        NavigationLink(value: value) {
            #if os(tvOS)
            // Artwork and captions are intentionally flat siblings, not nested in
            // a stack — the borderless style arranges them into a vertical lockup
            // and moves the captions out of the way as the artwork lifts.
            artwork
            titleText
            subtitleText
            #else
            // Other platforms don't apply the borderless lockup, so multiple
            // direct label children lay out horizontally. Stack them explicitly
            // to keep the captions below the artwork.
            VStack(spacing: SpacingTokens.xs) {
                artwork
                titleText
                subtitleText
            }
            #endif
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var artwork: some View {
        ArtworkImage(url: url, blurHash: blurHash, placeholderIcon: placeholderIcon)
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
    }

    private var titleText: some View {
        Text(title)
            .font(theme.jsTitle)
            .fontWeight(.semibold)
            .foregroundStyle(theme.primary)
            .lineLimit(1)
            .frame(width: width)
    }

    private var subtitleText: some View {
        // Reserve the second line even when empty so cards with one vs. two
        // caption lines stay aligned across a row.
        Text(subtitle ?? " ")
            .font(theme.jsBody)
            .fontWeight(.semibold)
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            .frame(width: width)
            .opacity(subtitle == nil ? 0 : 1)
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

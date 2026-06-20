import SwiftUI

/// A focusable, non-navigating cast/crew card for use inside a ``ContentShelf``.
///
/// Mirrors ``ArtworkShelfItem``'s tvOS focus treatment — the circular headshot and
/// its two caption lines are flat siblings inside a borderless `Button` so the
/// `.borderless` style lifts the artwork and slides the captions aside on focus.
/// The button has no action; cast members don't have a detail destination.
public struct CastCard: View {
    private let url: URL?
    private let name: String
    private let role: String?
    private let width: CGFloat

    @Environment(\.theme) private var theme

    public init(url: URL?, name: String, role: String? = nil, width: CGFloat = 200) {
        self.url = url
        self.name = name
        self.role = role
        self.width = width
    }

    public var body: some View {
        Button {
            // Cast members have no detail destination; the button exists only to
            // get the standard tvOS focus lift/highlight.
        } label: {
            #if os(tvOS)
            // Flat siblings so the borderless style builds the vertical lockup and
            // moves the captions out of the way as the artwork lifts.
            artwork
            nameText
            roleText
            #else
            VStack(spacing: SpacingTokens.xs) {
                artwork
                nameText
                roleText
            }
            #endif
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var artwork: some View {
        ArtworkImage(url: url, placeholderIcon: "person.fill")
            .frame(width: width, height: width)
            .clipShape(Circle())
            .artworkHighlightOnFocus()
    }

    private var nameText: some View {
        Text(name)
            .font(.jsCaption)
            .foregroundStyle(theme.primary)
            .lineLimit(1)
            .frame(width: width)
    }

    private var roleText: some View {
        // Reserve the second line even when empty so cards stay aligned across a row.
        Text(role ?? " ")
            .font(.jsCaption)
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            .frame(width: width)
            .opacity(role == nil ? 0 : 1)
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

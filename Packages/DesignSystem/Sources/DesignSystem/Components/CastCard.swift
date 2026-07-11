import SwiftUI

/// A focusable cast/crew card for use inside a ``ContentShelf``.
///
/// Mirrors ``ArtworkShelfItem``'s tvOS focus treatment — the circular headshot and
/// its two caption lines are flat siblings inside a borderless control so the
/// `.borderless` style lifts the artwork and slides the captions aside on focus.
///
/// Navigation is value-based, as in ``ArtworkShelfItem``: the card appends
/// `value` to the enclosing `NavigationStack`'s path and the stack's
/// `navigationDestination(for:)` resolves the person screen. The value-less
/// variant renders a no-op button that keeps the focus lift for people who
/// can't be navigated to (no server ID).
public struct CastCard<Value: Hashable>: View {
    private let url: URL?
    private let name: String
    private let role: String?
    private let width: CGFloat
    private let value: Value?

    @Environment(\.theme) private var theme

    /// Navigating variant: pushes `value` onto the enclosing stack.
    public init(url: URL?, name: String, role: String? = nil, width: CGFloat = 200, value: Value) {
        self.url = url
        self.name = name
        self.role = role
        self.width = width
        self.value = value
    }

    /// Non-navigating variant: the button exists only to get the standard
    /// tvOS focus lift/highlight. `Value` is meaningless here; the `Bool`
    /// constraint just pins the generic.
    public init(url: URL?, name: String, role: String? = nil, width: CGFloat = 200) where Value == Bool {
        self.url = url
        self.name = name
        self.role = role
        self.width = width
        self.value = nil
    }

    public var body: some View {
        Group {
            if let value {
                NavigationLink(value: value) {
                    cardLabel
                }
            } else {
                Button {
                    // No destination for this person; the button exists only to
                    // get the standard tvOS focus lift/highlight.
                } label: {
                    cardLabel
                }
            }
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        #else
        .buttonStyle(.plain)
        #endif
        // Read the card as a single element ("Name, Role") rather than three.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(role.map { "\(name), \($0)" } ?? name)
    }

    @ViewBuilder
    private var cardLabel: some View {
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

    private var artwork: some View {
        ArtworkImage(url: url, placeholderIcon: "person.fill")
            .frame(width: width, height: width)
            .clipShape(Circle())
            // Lift, specular highlight, and gimbal motion on focus.
            .hoverEffect(.highlight)
    }

    private var nameText: some View {
        Text(name)
            .jsStyle(.title)
            .foregroundStyle(theme.primary)
            .lineLimit(1)
            .frame(width: width)
    }

    private var roleText: some View {
        // Reserve the second line even when empty so cards stay aligned across a row.
        Text(role ?? " ")
            .jsStyle(.body)
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            .frame(width: width)
            .opacity(role == nil ? 0 : 1)
    }
}

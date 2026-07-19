import SwiftUI

/// Wraps one caption line of a shelf card so it dims while the card is idle and
/// comes to full strength on focus — focus reinforcement that reaches past the
/// artwork's lift to the whole lockup.
///
/// Must be constructed **inside** the button/link label: `\.isFocused` only
/// resolves within the focusable subtree, not on the view that owns the link
/// (the same trap ``GenreShelfItem`` documents).
///
/// One line per wrapper rather than one wrapper around the caption block,
/// because the tvOS lockup needs artwork and captions to stay flat siblings —
/// see ``ArtworkShelfItem``.
struct ShelfCaption<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A line reserved for layout but with nothing to say (a nil subtitle or
    /// role). It stays fully transparent regardless of focus.
    var isPlaceholder: Bool = false

    @ViewBuilder var content: Content

    var body: some View {
        content
            .opacity(isPlaceholder ? 0 : (isFocused ? 1 : MotionTokens.captionIdleOpacity))
            .animation(reduceMotion ? nil : theme.animation, value: isFocused)
    }
}

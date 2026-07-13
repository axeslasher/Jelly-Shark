import SwiftUI

/// A horizontal shelf of content with a themed header.
///
/// Provides the standard tvOS shelf layout: a title (with an optional SF Symbol
/// icon) above a horizontally scrolling row. The scroll view disables clipping so
/// focus-scaled items can lift past the shelf edges, and the content is padded to
/// the screen margin so cards scroll edge-to-edge with lead-in space.
///
/// Callers supply their own items via `@ViewBuilder` content — typically a
/// `ForEach` of ``ArtworkShelfItem`` — so a shelf can mix card shapes freely.
public struct ContentShelf<Content: View>: View {
    private let title: String
    private let icon: String?
    private let headerVisible: Bool
    private let content: Content

    /// How far below its resting spot the header sits while hidden, so a
    /// reveal reads as a fade + upward slide.
    private static var headerHiddenSlide: CGFloat {
        18
    }

    @Environment(\.theme) private var theme

    /// - Parameter headerVisible: Fades/slides the header away while false
    ///   (its layout space is kept, so the cards never reflow). Used by
    ///   shelves that sit under a hero and reveal their header only once the
    ///   hero has left the screen.
    public init(
        _ title: String,
        icon: String? = nil,
        headerVisible: Bool = true,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.icon = icon
        self.headerVisible = headerVisible
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            HStack(spacing: SpacingTokens.xs) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(theme.accent)
                }

                Text(title)
                    .jsStyle(.headline)
                    .foregroundStyle(theme.primary)
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .opacity(headerVisible ? 1 : 0)
            .offset(y: headerVisible ? 0 : Self.headerHiddenSlide)
            .animation(theme.animation, value: headerVisible)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                    content
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
                .padding(.vertical, SpacingTokens.focusPadding)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
    }
}

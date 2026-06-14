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
    private let content: Content

    @Environment(\.theme) private var theme

    public init(
        _ title: String,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            HStack(spacing: SpacingTokens.sm) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(theme.accent)
                }

                Text(title)
                    .font(.jsHeadline)
                    .foregroundStyle(theme.primary)
            }
            .padding(.horizontal, SpacingTokens.screenPadding)

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

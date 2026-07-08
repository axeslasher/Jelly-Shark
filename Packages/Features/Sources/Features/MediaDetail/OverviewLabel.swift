import DesignSystem
import SwiftUI

/// Truncated tagline + overview lockup, used as the label of a `.plain` button
/// that reveals the full text in an ``OverviewOverlay`` (the media detail hero's
/// description, the person page's biography).
///
/// When the `.plain` button gains focus, tvOS lifts the label onto a light
/// system platter — the theme's regular content colors are designed for the
/// dark backdrop and disappear against it, so the text swaps to the theme's
/// on-platter colors. `\.isFocused` is only populated inside the focusable's
/// subtree, which is why this is its own view rather than inline at the call
/// sites.
struct OverviewLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let tagline: String?
    let overview: String?
    /// On-page clamp for the overview text; the overlay shows the full text.
    var overviewLineLimit: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            if let tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(theme.jsHeadline)
                    .foregroundStyle(isFocused ? theme.onFocusFill : theme.primary)
                    .lineLimit(2)
            }
            if let overview {
                Text(overview)
                    .font(theme.jsOverview)
                    .foregroundStyle(isFocused ? theme.onFocusFillSecondary : theme.secondary)
                    .lineSpacing(4)
                    .lineLimit(overviewLineLimit)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(theme.animation, value: isFocused)
    }
}

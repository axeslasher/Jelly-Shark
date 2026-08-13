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

    /// Small uppercase label directly over the tagline (the `CreditEntry`
    /// label treatment) — the episode page's "Season 4 · Episode 1".
    var eyebrow: String?
    let tagline: String?
    let overview: String?
    /// On-page clamp for the overview text; the overlay shows the full text.
    var overviewLineLimit: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            if eyebrow != nil || tagline?.isEmpty == false {
                VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                    if let eyebrow {
                        Text(eyebrow)
                            .jsStyle(.eyebrow)
                            .foregroundStyle(isFocused ? theme.onFocusFillSecondary : theme.tertiary)
                            .textCase(.uppercase)
                    }
                    if let tagline, !tagline.isEmpty {
                        Text(tagline)
                            .jsStyle(.headline)
                            .foregroundStyle(isFocused ? theme.onFocusFill : theme.primary)
                            .lineLimit(2)
                    }
                }
            }
            if let overview {
                Text(overview)
                    .jsStyle(.overview)
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

#if DEBUG
    /// The lockup lives inside a `.plain` button; on focus the text swaps to
    /// the on-platter colors, which the static render can't show.
    private struct OverviewLabelPreview: View {
        var body: some View {
            VStack(alignment: .leading, spacing: SpacingTokens.xl) {
                Button {} label: {
                    OverviewLabel(
                        tagline: PreviewData.movie.tagline,
                        overview: PreviewData.movie.overview,
                    )
                }
                .buttonStyle(.plain)

                Button {} label: {
                    OverviewLabel(
                        eyebrow: "Season 2 · Episode 4",
                        tagline: nil,
                        overview: PreviewData.episode.overview,
                    )
                }
                .buttonStyle(.plain)
            }
            .frame(width: 880)
            .padding(SpacingTokens.xl)
        }
    }

    #Preview("Standard") {
        OverviewLabelPreview().previewCanvas()
    }

    #Preview("Horror") {
        OverviewLabelPreview().previewCanvas(.horror)
    }

    #Preview("Action") {
        OverviewLabelPreview().previewCanvas(.action)
    }

    #Preview("Video Store") {
        OverviewLabelPreview().previewCanvas(.videoStore)
    }

    #Preview("Sci-Fi") {
        OverviewLabelPreview().previewCanvas(.sciFi)
    }
#endif

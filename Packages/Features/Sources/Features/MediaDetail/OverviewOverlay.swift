import DesignSystem
import SwiftUI

/// Full-screen reading view for the overview, layered over the same dimmed,
/// blurred backdrop used by the hero once it scrolls below the fold. The text
/// scrolls (long synopses would otherwise clip with no way to read the rest)
/// and a Close button provides an explicit dismissal affordance.
struct OverviewOverlay: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Small uppercase label over the tagline, matching `OverviewLabel` —
    /// the episode page's "Season 4 · Episode 1".
    var eyebrow: String?
    let tagline: String?
    let overview: String?
    let backdropURL: URL?

    var body: some View {
        ZStack {
            theme.background
            if let backdropURL {
                ArtworkImage(url: backdropURL)
                    .opacity(0.3)
                    .blur(radius: 20)
            }
            ScrollView {
                VStack(alignment: .center, spacing: SpacingTokens.md) {
                    if let eyebrow {
                        Text(eyebrow)
                            .jsStyle(.eyebrow)
                            .foregroundStyle(theme.tertiary)
                            .textCase(.uppercase)
                    }
                    if let tagline, !tagline.isEmpty {
                        Text(tagline)
                            .jsStyle(.headline)
                            .foregroundStyle(theme.primary)
                    }
                    if let overview {
                        Text(overview)
                            .jsStyle(.title)
                            .foregroundStyle(theme.primary)
                            .lineSpacing(4)
                        // On tvOS the focus engine drives scrolling; a
                        // focusable text block lets the remote move through
                        // long synopses.
                        #if os(tvOS)
                            .focusable()
                        #endif
                    }

                    Button("Close") {
                        dismiss()
                    }
                    .glassButtonStyle(tint: theme.focusFill)
                    .padding(.top, SpacingTokens.lg)
                }
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SpacingTokens.xxl)
            }
        }
        .ignoresSafeArea()
    }
}

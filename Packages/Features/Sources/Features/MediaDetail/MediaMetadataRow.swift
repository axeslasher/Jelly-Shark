import DesignSystem
import SwiftUI

/// Inline year · runtime · rating · rated row, each with an SF Symbol, omitting
/// any missing field. The official rating renders as a bordered certificate
/// badge. Renders nothing at all when every field is nil, so the call site can
/// mount it unconditionally without contributing an empty stack spacing slot.
struct MediaMetadataRow: View {
    @Environment(\.theme) private var theme

    let year: Int?
    let runtime: String?
    let communityRating: Double?
    let certificate: String?

    /// Whether any metadata field is present, so the row can skip rendering
    /// entirely rather than producing an empty stack.
    private var hasContent: Bool {
        year != nil || runtime != nil || communityRating != nil || certificate != nil
    }

    var body: some View {
        if hasContent {
            HStack(alignment: .center, spacing: SpacingTokens.md) {
                if let year {
                    // Verbatim string on purpose: a number format would group the
                    // digits ("2,024") in some locales.
                    Label(String(year), systemImage: "calendar")
                }
                if let runtime {
                    Label(runtime, systemImage: "clock")
                }
                if let rating = communityRating {
                    Label {
                        Text(rating, format: .number.precision(.fractionLength(1)))
                    } icon: {
                        Image(systemName: "star.fill")
                    }
                }
                if let certificate {
                    Text(certificate)
                        // Ratings badge always uses Zodiak, regardless of the active
                        // theme's font scheme. Falls back to the system font if Zodiak
                        // isn't installed (same behavior as the scheme resolver).
                        .font(.custom(FontFamily.zodiak, fixedSize: TypographyTokens.Size.caption))
                        .fontWeight(.bold)
                        .padding(.horizontal, SpacingTokens.xs)
                        .padding(.vertical, SpacingTokens.xxs)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.tertiary, lineWidth: 2)
                        )
                }
            }
            .font(theme.jsBody)
            .foregroundStyle(theme.tertiary)
            .fontWeight(.bold)
            .labelStyle(MetadataLabelStyle(spacing: SpacingTokens.xs))
        }
    }
}

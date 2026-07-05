import DesignSystem
import SwiftUI

/// Inline year · runtime/seasons · ratings · certificate row, each with an SF
/// Symbol, omitting any missing field, with a second row of bordered technical
/// badges (resolution, dynamic range, audio format, CC) beneath it. The
/// official rating renders as a bordered certificate badge. Renders nothing at
/// all when every field is nil, so the call site can mount it unconditionally
/// without contributing an empty stack spacing slot.
struct MediaMetadataRow: View {
    @Environment(\.theme) private var theme

    /// Display year ("2024") or series span ("2008–2013", "2008–")
    let yearText: String?
    let runtime: String?
    /// Series season count ("3 Seasons"); shown in place of runtime for series
    let seasons: String?
    let communityRating: Double?
    /// Critic score on a 0–100 scale, rendered as a percentage
    let criticRating: Double?
    let certificate: String?
    /// Short technical labels ("4K", "Dolby Vision", "Atmos", "CC")
    let techBadges: [String]

    /// Whether any metadata field is present, so the row can skip rendering
    /// entirely rather than producing an empty stack.
    private var hasContent: Bool {
        yearText != nil || runtime != nil || seasons != nil
            || communityRating != nil || criticRating != nil
            || certificate != nil || !techBadges.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                factsRow
                if !techBadges.isEmpty {
                    badgesRow
                }
            }
            .font(theme.jsBody)
            .foregroundStyle(theme.tertiary)
            .fontWeight(.bold)
            .labelStyle(MetadataLabelStyle(spacing: SpacingTokens.xs))
        }
    }

    @ViewBuilder
    private var factsRow: some View {
        HStack(alignment: .center, spacing: SpacingTokens.md) {
            if let yearText {
                Label(yearText, systemImage: "calendar")
            }
            if let seasons {
                Label(seasons, systemImage: "square.stack")
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
            if let critic = criticRating {
                Label {
                    Text("\(Int(critic.rounded()))%")
                } icon: {
                    Image(systemName: "rosette")
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
    }

    private var badgesRow: some View {
        HStack(alignment: .center, spacing: SpacingTokens.xs) {
            ForEach(techBadges, id: \.self) { badge in
                Text(badge)
                    .font(theme.jsCaption)
                    .fontWeight(.bold)
                    .textCase(.uppercase)
                    .tracking(TypographyTokens.Tracking.wide)
                    .padding(.horizontal, SpacingTokens.xs)
                    .padding(.vertical, SpacingTokens.xxs)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.tertiary, lineWidth: 1.5)
                    )
            }
        }
    }
}

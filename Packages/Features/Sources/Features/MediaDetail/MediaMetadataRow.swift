import DesignSystem
import SwiftUI

/// Inline year · runtime/seasons · ratings · certificate · technical facts
/// row, omitting any missing field. Facts carry SF Symbols (resolution gets
/// the dedicated `4k.tv` glyph when it applies, audio a speaker); the dynamic
/// range renders as plain text since no SF Symbol exists for it. The official
/// rating renders as a bordered certificate badge. Renders nothing at all when
/// every field is nil, so the call site can mount it unconditionally without
/// contributing an empty stack spacing slot.
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
    /// Resolution class ("4K", "1080p", …)
    let resolution: String?
    /// Dynamic-range label ("Dolby Vision", "HDR10", …)
    let videoRange: String?
    /// Audio format ("Dolby Atmos", "5.1", …)
    let audioFormat: String?

    /// Whether any metadata field is present, so the row can skip rendering
    /// entirely rather than producing an empty stack.
    private var hasContent: Bool {
        yearText != nil || runtime != nil || seasons != nil
            || communityRating != nil || criticRating != nil
            || certificate != nil || resolution != nil
            || videoRange != nil || audioFormat != nil
    }

    var body: some View {
        if hasContent {
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
                if let resolution {
                    // Only 4K has a dedicated SF Symbol; other classes get the
                    // generic screen glyph.
                    Label(resolution, systemImage: resolution == "4K" ? "4k.tv" : "tv")
                }
                if let videoRange {
                    Text(videoRange)
                }
                if let audioFormat {
                    Label(audioFormat, systemImage: "hifispeaker.fill")
                }
            }
            .font(theme.jsBody)
            .foregroundStyle(theme.tertiary)
            .fontWeight(.bold)
            .labelStyle(MetadataLabelStyle(spacing: SpacingTokens.xs))
        }
    }
}

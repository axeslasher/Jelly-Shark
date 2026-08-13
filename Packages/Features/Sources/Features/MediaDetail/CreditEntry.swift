import DesignSystem
import SwiftUI

/// A small labeled fact: uppercase eyebrow label over a body value. The shared
/// typographic unit of the hero's credits column and the info section below
/// the shelves.
struct CreditEntry: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String
    var lineLimit: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
            Text(label)
                .jsStyle(.eyebrow)
                .foregroundStyle(theme.tertiary)
                .textCase(.uppercase)
            Text(value)
                .jsStyle(.body, .emphasized)
                .foregroundStyle(theme.secondary)
                .lineLimit(lineLimit)
        }
    }
}

#Preview("Standard") {
    VStack(alignment: .leading, spacing: SpacingTokens.lg) {
        CreditEntry(label: "Director", value: "Marisol Vane")
        CreditEntry(
            label: "Starring",
            value: "Teddy Okafor, June Castellane, Arno Pike, Priya Ramanathan, and Wallace Thorn",
        )
    }
    .frame(width: 480, alignment: .leading)
    .padding(SpacingTokens.xl)
    .previewCanvas()
}

#Preview("Horror") {
    VStack(alignment: .leading, spacing: SpacingTokens.lg) {
        CreditEntry(label: "Director", value: "Marisol Vane")
        CreditEntry(
            label: "Starring",
            value: "Teddy Okafor, June Castellane, Arno Pike, Priya Ramanathan, and Wallace Thorn",
        )
    }
    .frame(width: 480, alignment: .leading)
    .padding(SpacingTokens.xl)
    .previewCanvas(.horror)
}

#Preview("Action") {
    VStack(alignment: .leading, spacing: SpacingTokens.lg) {
        CreditEntry(label: "Director", value: "Marisol Vane")
        CreditEntry(
            label: "Starring",
            value: "Teddy Okafor, June Castellane, Arno Pike, Priya Ramanathan, and Wallace Thorn",
        )
    }
    .frame(width: 480, alignment: .leading)
    .padding(SpacingTokens.xl)
    .previewCanvas(.action)
}

#Preview("Video Store") {
    VStack(alignment: .leading, spacing: SpacingTokens.lg) {
        CreditEntry(label: "Director", value: "Marisol Vane")
        CreditEntry(
            label: "Starring",
            value: "Teddy Okafor, June Castellane, Arno Pike, Priya Ramanathan, and Wallace Thorn",
        )
    }
    .frame(width: 480, alignment: .leading)
    .padding(SpacingTokens.xl)
    .previewCanvas(.videoStore)
}

#Preview("Sci-Fi") {
    VStack(alignment: .leading, spacing: SpacingTokens.lg) {
        CreditEntry(label: "Director", value: "Marisol Vane")
        CreditEntry(
            label: "Starring",
            value: "Teddy Okafor, June Castellane, Arno Pike, Priya Ramanathan, and Wallace Thorn",
        )
    }
    .frame(width: 480, alignment: .leading)
    .padding(SpacingTokens.xl)
    .previewCanvas(.sciFi)
}

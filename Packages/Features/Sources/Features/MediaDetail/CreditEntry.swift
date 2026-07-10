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

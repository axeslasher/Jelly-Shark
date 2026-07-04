import DesignSystem
import SwiftUI

/// Director / Starring credit stacks, list-formatted so separators and
/// conjunctions follow the locale ("A, B, and C"). Renders nothing when both
/// name lists are empty.
struct CreditsColumn: View {
    @Environment(\.theme) private var theme

    let directorNames: [String]
    let castNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            if !directorNames.isEmpty {
                creditStack(
                    label: directorNames.count > 1 ? "Directed by" : "Director",
                    names: directorNames
                )
            }
            if !castNames.isEmpty {
                creditStack(label: "Starring", names: castNames)
            }
        }
    }

    private func creditStack(label: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
            Text(label)
                .font(theme.jsCaption)
                .foregroundStyle(theme.tertiary)
                .fontWeight(.bold)
                .textCase(.uppercase)
                .tracking(TypographyTokens.Tracking.wide)
            Text(names, format: .list(type: .and))
                .font(theme.jsBody)
                .foregroundStyle(theme.secondary)
                .fontWeight(.semibold)
                .lineLimit(2)
        }
    }
}

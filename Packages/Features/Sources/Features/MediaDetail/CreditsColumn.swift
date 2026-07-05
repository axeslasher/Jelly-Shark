import DesignSystem
import SwiftUI

/// Director / Starring / Studio credit stacks, list-formatted so separators
/// and conjunctions follow the locale ("A, B, and C"). Renders nothing when
/// all name lists are empty.
struct CreditsColumn: View {
    @Environment(\.theme) private var theme

    let directorNames: [String]
    let castNames: [String]
    let studioNames: [String]

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
            if !studioNames.isEmpty {
                creditStack(
                    label: studioNames.count > 1 ? "Studios" : "Studio",
                    // Studio lists can run long ("A, B, C, and D presents…");
                    // the first credit is the meaningful one on a lockup.
                    names: Array(studioNames.prefix(2))
                )
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

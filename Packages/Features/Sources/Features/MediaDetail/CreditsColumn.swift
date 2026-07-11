import DesignSystem
import SwiftUI

/// Director / Starring credit stacks, list-formatted so separators and
/// conjunctions follow the locale ("A, B, and C"). Renders nothing when both
/// name lists are empty.
struct CreditsColumn: View {
    let directorNames: [String]
    let castNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            if !directorNames.isEmpty {
                CreditEntry(
                    label: directorNames.count > 1 ? "Directed by" : "Director",
                    value: directorNames.formatted(.list(type: .and)),
                )
            }
            if !castNames.isEmpty {
                CreditEntry(
                    label: "Starring",
                    value: castNames.formatted(.list(type: .and)),
                )
            }
        }
    }
}

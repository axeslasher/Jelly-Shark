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

#if DEBUG
    private struct CreditsColumnPreview: View {
        var body: some View {
            VStack(alignment: .leading, spacing: SpacingTokens.xl) {
                CreditsColumn(
                    directorNames: [PreviewData.cast[6].name],
                    castNames: PreviewData.cast.prefix(4).map(\.name),
                )
                // Single director relabels the eyebrow; no cast drops that stack.
                CreditsColumn(directorNames: [PreviewData.cast[6].name], castNames: [])
            }
            .frame(width: 520, alignment: .leading)
            .padding(SpacingTokens.xl)
        }
    }

    #Preview("Standard") {
        CreditsColumnPreview().previewCanvas()
    }

    #Preview("Horror") {
        CreditsColumnPreview().previewCanvas(.horror)
    }

    #Preview("Action") {
        CreditsColumnPreview().previewCanvas(.action)
    }

    #Preview("Video Store") {
        CreditsColumnPreview().previewCanvas(.videoStore)
    }

    #Preview("Sci-Fi") {
        CreditsColumnPreview().previewCanvas(.sciFi)
    }
#endif

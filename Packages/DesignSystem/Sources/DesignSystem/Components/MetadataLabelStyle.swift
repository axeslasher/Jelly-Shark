import SwiftUI

/// A `Label` layout with explicit icon↔title spacing, since `Label` exposes none.
public struct MetadataLabelStyle: LabelStyle {
    private let spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
    }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

private struct MetadataLabelStylePreview: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            Label("2h 14m", systemImage: "clock")
                .labelStyle(MetadataLabelStyle(spacing: SpacingTokens.xs))
            Label("Tight spacing", systemImage: "ruler")
                .labelStyle(MetadataLabelStyle(spacing: 2))
        }
        .jsStyle(.caption)
        .foregroundStyle(theme.secondary)
        .padding(SpacingTokens.xl)
    }
}

#Preview("Standard") {
    MetadataLabelStylePreview()
        .previewCanvas()
}

#Preview("Horror") {
    MetadataLabelStylePreview()
        .previewCanvas(.horror)
}

#Preview("Action") {
    MetadataLabelStylePreview()
        .previewCanvas(.action)
}

#Preview("Video Store") {
    MetadataLabelStylePreview()
        .previewCanvas(.videoStore)
}

#Preview("Sci-Fi") {
    MetadataLabelStylePreview()
        .previewCanvas(.sciFi)
}

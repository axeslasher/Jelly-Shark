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

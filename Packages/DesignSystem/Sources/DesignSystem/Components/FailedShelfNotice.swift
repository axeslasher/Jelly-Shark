import SwiftUI

/// A section whose primary load failed: the shelf header stays (mirroring
/// `ContentShelf`'s) with a one-line notice where the cards would be, plus —
/// when a `retry` action is provided — a focusable Retry button.
///
/// The Retry button is deliberately the notice's only focusable: besides
/// offering recovery in place, it gives an otherwise-empty shelves region a
/// landing spot for the tvOS focus engine, so a page whose sections all
/// failed doesn't become unreachable below the fold. The UI copy stays fixed
/// and friendly; the underlying `error.localizedDescription` lives in the
/// owning view model's status for tests and diagnostics.
public struct FailedShelfNotice: View {
    @Environment(\.theme) private var theme

    private let title: LocalizedStringResource?
    private let icon: String?
    private let message: LocalizedStringResource
    private let retry: (() -> Void)?

    /// - Parameter message: The caller's own copy; nil shows the generic
    ///   connection message. Not a default argument: `#bundle` there would
    ///   resolve to the caller's bundle, which has no such string.
    public init(
        title: LocalizedStringResource? = nil,
        icon: String? = nil,
        message: LocalizedStringResource? = nil,
        retry: (() -> Void)? = nil,
    ) {
        self.title = title
        self.icon = icon
        self.message = message ?? Self.defaultMessage
        self.retry = retry
    }

    private static var defaultMessage: LocalizedStringResource {
        LocalizedStringResource("shelf.failed.message", bundle: #bundle, comment: "Shown where a row of posters would be when it failed to load.")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
            if let title {
                HStack(spacing: SpacingTokens.xs) {
                    if let icon {
                        Image(systemName: icon)
                            .foregroundStyle(theme.accent)
                    }
                    Text(title)
                        .jsStyle(.headline)
                        .foregroundStyle(theme.primary)
                }
            }

            HStack(spacing: SpacingTokens.md) {
                Label(message, systemImage: "wifi.exclamationmark")
                    .jsStyle(.title)
                    .foregroundStyle(theme.secondary)

                if let retry {
                    Button(action: retry) {
                        Label(LocalizedStringResource("shelf.failed.retry", bundle: #bundle, comment: "Button that reloads a row of posters that failed to load."), systemImage: "arrow.clockwise")
                            .jsStyle(.title)
                    }
                    .glassButtonStyle(tint: theme.focusFill)
                }
            }
            .padding(.vertical, SpacingTokens.md)
        }
        .padding(.horizontal, SpacingTokens.screenPadding)
    }
}

#Preview("Standard") {
    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
        FailedShelfNotice(title: "Continue Watching", icon: "play.circle", retry: {})
        FailedShelfNotice()
    }
    .previewCanvas()
}

#Preview("Horror") {
    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
        FailedShelfNotice(title: "Continue Watching", icon: "play.circle", retry: {})
        FailedShelfNotice()
    }
    .previewCanvas(.horror)
}

#Preview("Action") {
    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
        FailedShelfNotice(title: "Continue Watching", icon: "play.circle", retry: {})
        FailedShelfNotice()
    }
    .previewCanvas(.action)
}

#Preview("Video Store") {
    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
        FailedShelfNotice(title: "Continue Watching", icon: "play.circle", retry: {})
        FailedShelfNotice()
    }
    .previewCanvas(.videoStore)
}

#Preview("Sci-Fi") {
    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
        FailedShelfNotice(title: "Continue Watching", icon: "play.circle", retry: {})
        FailedShelfNotice()
    }
    .previewCanvas(.sciFi)
}

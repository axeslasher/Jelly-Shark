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

    private let title: String?
    private let icon: String?
    private let message: String
    private let retry: (() -> Void)?

    public init(
        title: String? = nil,
        icon: String? = nil,
        message: String = "Couldn't load — check your connection",
        retry: (() -> Void)? = nil,
    ) {
        self.title = title
        self.icon = icon
        self.message = message
        self.retry = retry
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
                        Label("Retry", systemImage: "arrow.clockwise")
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

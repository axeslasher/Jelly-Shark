import DesignSystem
import SwiftUI

/// The reconnecting affordance over a stalled player (#188): a compact card
/// at the top-leading corner naming what the server is doing and how to
/// leave, over a frame that stays exactly where it froze.
///
/// Passive by design. AVKit keeps retrying underneath — both measured
/// outages healed on their own — so there is nothing for the viewer to
/// press except the exit they already have, and the card names it rather
/// than adding a control: a SwiftUI sibling cannot take focus from a live
/// `AVPlayerViewController`, and the host this renders in
/// (`contentOverlayView`) takes no interaction at all.
///
/// Takes an optional so the host can stay mounted for the whole session
/// and let the card animate in and out here, instead of adding and
/// removing a view over the player mid-playback.
///
/// Hosted in a UIKit tree detached from the app's, so the host re-applies
/// the theme at the root it wraps this in
/// (`PlayerViewControllerRepresentable.reconnectingBannerRoot`). It cannot
/// be applied here: this view's own `@Environment(\.theme)` read sits above
/// any modifier its body adds.
struct ReconnectingBanner: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let outage: ServerOutage?

    var body: some View {
        VStack(alignment: .leading) {
            if let outage {
                card(for: outage)
                    .transition(.opacity)
            }
        }
        .padding(SpacingTokens.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : theme.animation, value: outage)
    }

    private func card(for outage: ServerOutage) -> some View {
        HStack(alignment: .top, spacing: SpacingTokens.md) {
            Image(systemName: outage.symbolName)
                .font(.system(size: 36))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(outage.title)
                    .jsStyle(.headline)
                    .foregroundStyle(theme.primary)

                Text(outage.detail)
                    .jsStyle(.caption)
                    .foregroundStyle(theme.secondary)
            }
        }
        .padding(SpacingTokens.lg)
        // Builder form, not a direct ShapeStyle argument — see
        // `UpNextOverlayView` for the SDK 27 ambiguity it avoids
        .background { theme.surface.opacity(0.9) }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
                .stroke(theme.primary.opacity(0.12), lineWidth: theme.borderWidth)
        }
    }
}

// MARK: - Copy

extension ServerOutage {
    /// What the card leads with.
    var title: String {
        switch self {
        case .starting:
            "Server is starting up"
        case let .serverError(statusCode):
            "Server error (\(statusCode))"
        case .unreachable:
            "Connection lost"
        }
    }

    /// What is happening, and how to leave. The exit is named rather than
    /// offered as a control — see `ReconnectingBanner`.
    var detail: String {
        let status = switch self {
        case .starting:
            "Playback will resume when it's ready…"
        case .serverError:
            "Retrying…"
        case .unreachable:
            "Reconnecting to the server…"
        }
        return "\(status) \(Self.exitInstruction)"
    }

    /// The control that ends the session: the remote's Back button on tvOS,
    /// the player's own close control on visionOS (which has no Back).
    static var exitInstruction: String {
        #if os(visionOS)
            "Close the player to stop."
        #else
            "Press Back to stop."
        #endif
    }

    var symbolName: String {
        switch self {
        case .starting:
            "arrow.triangle.2.circlepath"
        case .serverError:
            "exclamationmark.triangle.fill"
        case .unreachable:
            "wifi.exclamationmark"
        }
    }
}

// MARK: - Previews

#if DEBUG
    /// All three states at once, so a theme's card is judged as a set
    private struct ReconnectingBannerSpecimen: View {
        var body: some View {
            VStack(alignment: .leading, spacing: SpacingTokens.lg) {
                ReconnectingBanner(outage: .unreachable)
                ReconnectingBanner(outage: .starting)
                ReconnectingBanner(outage: .serverError(statusCode: 500))
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    #Preview("Standard") {
        ReconnectingBannerSpecimen()
            .previewCanvas()
    }

    #Preview("Horror") {
        ReconnectingBannerSpecimen()
            .previewCanvas(.horror)
    }

    #Preview("Action") {
        ReconnectingBannerSpecimen()
            .previewCanvas(.action)
    }

    #Preview("Video Store") {
        ReconnectingBannerSpecimen()
            .previewCanvas(.videoStore)
    }

    #Preview("Sci-Fi") {
        ReconnectingBannerSpecimen()
            .previewCanvas(.sciFi)
    }
#endif

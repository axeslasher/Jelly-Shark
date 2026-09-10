import DesignSystem
import SwiftUI

/// The reconnecting affordance over a stalled player (#188): a compact card
/// at the top-leading corner naming what the server is doing and how to
/// leave, over a frame that stays exactly where it froze.
///
/// Passive by design: it reports and carries nothing to press. A SwiftUI
/// sibling cannot take focus from a live `AVPlayerViewController` and the
/// host this renders in (`contentOverlayView`) takes no interaction at all,
/// and there is nothing to offer anyway — AVKit keeps retrying underneath,
/// and both measured outages healed on their own.
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
        case .stalled:
            "Playback stalled"
        }
    }

    /// What is happening. The card states it and stops — the viewer's exit
    /// is the one they already know, and spelling it out on every outage
    /// reads as an instruction where none is needed.
    var detail: String {
        switch self {
        case .starting:
            "Playback will resume when it's ready…"
        case .serverError:
            "Retrying…"
        case .unreachable:
            "Reconnecting to the server…"
        case .stalled:
            "The server is back, but the video hasn't resumed."
        }
    }

    var symbolName: String {
        switch self {
        case .starting:
            "arrow.triangle.2.circlepath"
        case .serverError:
            "exclamationmark.triangle.fill"
        case .unreachable:
            "wifi.exclamationmark"
        case .stalled:
            "hourglass"
        }
    }
}

// MARK: - Previews

#if DEBUG
    /// Every state at once, so a theme's card is judged as a set
    private struct ReconnectingBannerSpecimen: View {
        var body: some View {
            VStack(alignment: .leading, spacing: SpacingTokens.lg) {
                ReconnectingBanner(outage: .unreachable)
                ReconnectingBanner(outage: .starting)
                ReconnectingBanner(outage: .serverError(statusCode: 500))
                ReconnectingBanner(outage: .stalled)
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

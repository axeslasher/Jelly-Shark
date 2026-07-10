import SwiftUI
import JellyfinKit
import DesignSystem

/// Overlay shown when an episode ends and the next one is queued
///
/// Counts down to autoplay; the user can start the next episode
/// immediately or cancel and end the session.
struct UpNextOverlayView: View {
    @Environment(\.theme) private var theme

    let nextEpisode: MediaItem
    let onPlayNow: () -> Void
    let onCancel: () -> Void

    @State private var secondsRemaining = 8
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            Text("Up Next")
                .jsStyle(.caption)
                .foregroundStyle(theme.secondary)

            Text(nextEpisode.episodeDisplayTitle ?? nextEpisode.name)
                .jsStyle(.title)
                .foregroundStyle(theme.primary)
                .lineLimit(2)

            HStack(spacing: SpacingTokens.md) {
                Button {
                    countdownTask?.cancel()
                    onPlayNow()
                } label: {
                    HStack(spacing: SpacingTokens.sm) {
                        Image(systemName: "play.fill")
                        Text("Play Now (\(secondsRemaining))")
                    }
                    .jsStyle(.body)
                }

                Button("Cancel") {
                    countdownTask?.cancel()
                    onCancel()
                }
                .jsStyle(.body)
            }
        }
        .padding(SpacingTokens.xl)
        .background(theme.surface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
        .padding(SpacingTokens.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onAppear {
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task {
            while secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                secondsRemaining -= 1
            }
            onPlayNow()
        }
    }
}

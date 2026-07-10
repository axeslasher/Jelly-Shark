import SwiftUI
import JellyfinKit
import DesignSystem

/// Full-screen container for video playback
///
/// Hosts the AVKit player, drives the playback view model lifecycle,
/// and presents loading, error, and Up Next states.
public struct PlaybackContainerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PlaybackViewModel

    public init(client: any JellyfinClientProtocol, item: MediaItem) {
        _viewModel = State(initialValue: PlaybackViewModel(client: client, item: item))
    }

    public var body: some View {
        ZStack {
            Color.black

            switch viewModel.state {
            case .idle, .loading:
                ProgressView()
                    .scaleEffect(1.5)

            case .playing:
                playerView

            case .failed(let message):
                errorView(message)

            case .finished:
                Color.black
            }

            if let next = viewModel.nextEpisode {
                UpNextOverlayView(
                    nextEpisode: next,
                    onPlayNow: {
                        Task { await viewModel.playNextEpisodeNow() }
                    },
                    onCancel: {
                        viewModel.cancelAutoplay()
                    }
                )
            }
        }
        .ignoresSafeArea()
        .task {
            await viewModel.start()
        }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .finished {
                dismiss()
            }
        }
        .onDisappear {
            Task { await viewModel.stop() }
        }
    }

    @ViewBuilder
    private var playerView: some View {
        #if canImport(UIKit)
        if let player = viewModel.player {
            PlayerViewControllerRepresentable(
                player: player,
                audioStreams: viewModel.mediaSource?.audioStreams ?? [],
                subtitleStreams: viewModel.mediaSource?.subtitleStreams ?? [],
                selectedAudioIndex: viewModel.selectedAudioStreamIndex,
                selectedSubtitleIndex: viewModel.selectedSubtitleStreamIndex,
                onSelectAudio: { index in
                    Task { await viewModel.selectAudioStream(index: index) }
                },
                onSelectSubtitle: { index in
                    Task { await viewModel.selectSubtitleStream(index: index) }
                }
            )
        }
        #else
        Text("Playback is not supported on this platform")
            .jsStyle(.body)
            .foregroundStyle(theme.secondary)
        #endif
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: SpacingTokens.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.tertiary)

            Text("Playback Failed")
                .jsStyle(.headline)
                .foregroundStyle(theme.primary)

            Text(message)
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SpacingTokens.xxl)

            Button("Close") {
                dismiss()
            }
            .jsStyle(.body)
        }
    }
}

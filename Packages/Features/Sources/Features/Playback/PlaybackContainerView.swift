import DesignSystem
import JellyfinKit
import SwiftUI

/// Full-screen container for video playback
///
/// Hosts the AVKit player, drives the playback view model lifecycle,
/// and presents loading, error, and Up Next states.
public struct PlaybackContainerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PlaybackViewModel

    /// The concrete engine, held alongside the view model: the AVKit
    /// hosting below needs the typed `player` the `PlayerEngine` protocol
    /// deliberately doesn't expose, and reading it here keeps SwiftUI
    /// re-rendering when a mid-session rebuild swaps the player instance.
    @State private var playerEngine: AVFoundationPlayerEngine

    /// Focus for the error screen's Close button. `.failed` used to be
    /// reachable only from `.loading`, whose ProgressView holds no focus, so
    /// the engine had one candidate and found it. A delivery failure (#151)
    /// arrives from `.playing`, tearing the focused AVKit player controller
    /// out from under the engine — this states the landing spot explicitly
    /// rather than trusting the recovery, because Close is the only exit.
    @FocusState private var isRetryFocused: Bool

    public init(client: any JellyfinClientProtocol, item: MediaItem) {
        let engine = AVFoundationPlayerEngine()
        _playerEngine = State(initialValue: engine)
        _viewModel = State(initialValue: PlaybackViewModel(client: client, item: item, engine: engine))
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

            case let .failed(message):
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
                    },
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
            if let player = playerEngine.player {
                PlayerViewControllerRepresentable(
                    player: player,
                    audioStreams: viewModel.mediaSource?.audioStreams ?? [],
                    subtitleStreams: viewModel.mediaSource?.subtitleStreams ?? [],
                    selectedAudioIndex: viewModel.selectedAudioStreamIndex,
                    selectedSubtitleIndex: viewModel.selectedSubtitleStreamIndex,
                    people: viewModel.castMembers,
                    isFavorite: viewModel.isFavorite,
                    headshotURL: { viewModel.headshotURL(for: $0) },
                    onSelectAudio: { index in
                        Task { await viewModel.selectAudioStream(index: index) }
                    },
                    onSelectSubtitle: { index in
                        Task { await viewModel.selectSubtitleStream(index: index) }
                    },
                    onToggleFavorite: {
                        Task { await viewModel.toggleFavorite() }
                    },
                )
                #if os(visionOS)
                .overlay(alignment: .topTrailing) {
                    trackSelectionMenu
                }
                #endif
            }
        #else
            Text("Playback is not supported on this platform")
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
        #endif
    }

    #if os(visionOS)
        /// Audio and burn-in subtitle pickers for visionOS, where AVKit's
        /// tvOS-only transport-bar menus are unavailable. Text subtitles are
        /// deliberately absent: they are HLS renditions the system player's
        /// own media-selection UI handles natively (#90). This overlay
        /// carries only the server-side options AVKit cannot see — alternate
        /// audio and burn-in subtitle tracks, which need a stream rebuild.
        @ViewBuilder
        private var trackSelectionMenu: some View {
            let audioStreams = viewModel.mediaSource?.audioStreams ?? []
            let subtitleStreams = (viewModel.mediaSource?.subtitleStreams ?? [])
                .filter { !$0.isTextSubtitleStream }

            if audioStreams.count > 1 || !subtitleStreams.isEmpty {
                Menu {
                    if audioStreams.count > 1 {
                        Picker("Audio", selection: audioSelection) {
                            ForEach(audioStreams, id: \.index) { stream in
                                Text(trackTitle(for: stream)).tag(stream.index)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if !subtitleStreams.isEmpty {
                        Picker("Image Subtitles", selection: subtitleSelection) {
                            Text("Off").tag(Int?.none)
                            ForEach(subtitleStreams, id: \.index) { stream in
                                Text(BurnInSubtitleLabel.title(for: stream)).tag(Int?.some(stream.index))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                        .accessibilityLabel("Audio and Subtitles")
                }
                .padding(SpacingTokens.xl)
            }
        }

        private var audioSelection: Binding<Int> {
            Binding(
                get: { viewModel.selectedAudioStreamIndex ?? -1 },
                set: { index in
                    Task { await viewModel.selectAudioStream(index: index) }
                },
            )
        }

        private var subtitleSelection: Binding<Int?> {
            Binding(
                get: { viewModel.selectedSubtitleStreamIndex },
                set: { index in
                    Task { await viewModel.selectSubtitleStream(index: index) }
                },
            )
        }

        private func trackTitle(for stream: MediaStreamInfo) -> String {
            stream.displayTitle ?? stream.language ?? "Track \(stream.index)"
        }
    #endif

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

            // Try Again leads and takes focus: every message on this screen
            // ends by suggesting another attempt, and until now the screen
            // offered no way to make one. Close stays as the way out.
            HStack(spacing: SpacingTokens.md) {
                Button("Try Again") {
                    Task { await viewModel.retry() }
                }
                .jsStyle(.body)
                .focused($isRetryFocused)

                Button("Close") {
                    dismiss()
                }
                .jsStyle(.body)
            }
        }
        // Focus is set rather than left to the engine: this screen is now
        // reachable from `.playing`, where a delivery failure tears the
        // focused AVKit controller out from under it.
        .onAppear { isRetryFocused = true }
    }
}

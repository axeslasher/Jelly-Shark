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
            if let player = viewModel.player {
                PlayerViewControllerRepresentable(
                    player: player,
                    audioStreams: viewModel.mediaSource?.audioStreams ?? [],
                    subtitleStreams: viewModel.mediaSource?.subtitleStreams ?? [],
                    selectedAudioIndex: viewModel.selectedAudioStreamIndex,
                    selectedSubtitleIndex: viewModel.selectedSubtitleStreamIndex,
                    people: viewModel.castMembers,
                    headshotURL: { viewModel.headshotURL(for: $0) },
                    onSelectAudio: { index in
                        Task { await viewModel.selectAudioStream(index: index) }
                    },
                    onSelectSubtitle: { index in
                        Task { await viewModel.selectSubtitleStream(index: index) }
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
        /// Audio and subtitle pickers for visionOS, where AVKit's
        /// tvOS-only transport-bar menus are unavailable. The system
        /// player's own media-selection button can't be used either: it
        /// only sees AVPlayer-level tracks, not server-side options like
        /// burn-in subtitles or alternate audio that need a stream rebuild.
        @ViewBuilder
        private var trackSelectionMenu: some View {
            let audioStreams = viewModel.mediaSource?.audioStreams ?? []
            let subtitleStreams = viewModel.mediaSource?.subtitleStreams ?? []

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
                        Picker("Subtitles", selection: subtitleSelection) {
                            Text("Off").tag(Int?.none)
                            ForEach(subtitleStreams, id: \.index) { stream in
                                Text(trackTitle(for: stream)).tag(Int?.some(stream.index))
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

            Button("Close") {
                dismiss()
            }
            .jsStyle(.body)
        }
    }
}

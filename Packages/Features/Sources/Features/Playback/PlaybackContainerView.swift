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
    @Environment(ContentRefreshCoordinator.self) private var refreshCoordinator

    @State private var viewModel: PlaybackViewModel

    /// Set by `.task` at presentation; `onDisappear` reads it to hand the
    /// same session to `finishPlayback`. Nil only if `.task` never ran.
    @State private var playbackTicket: ContentRefreshCoordinator.PlaybackTicket?

    /// The concrete engine, held alongside the view model: the AVKit
    /// hosting below needs the typed `player` the `PlayerEngine` protocol
    /// deliberately doesn't expose, and reading it here is what gets the
    /// first load onto the screen. A rebuild keeps the same instance and
    /// swaps the item inside it, so nothing here re-renders mid-session.
    @State private var playerEngine: AVFoundationPlayerEngine

    /// Focus for the error screen's Close button. `.failed` used to be
    /// reachable only from `.loading`, whose ProgressView holds no focus, so
    /// the engine had one candidate and found it. A delivery failure (#151)
    /// arrives from `.playing`, tearing the focused AVKit player controller
    /// out from under the engine — this states the landing spot explicitly
    /// rather than trusting the recovery, because Close is the only exit.
    @FocusState private var isRetryFocused: Bool

    /// - Parameters:
    ///   - mediaSourceId: the version the launch surface chose (#147); nil
    ///     plays the server default
    ///   - streamingBitrateCap: the viewer's streaming ceiling in bits per
    ///     second (#168); nil leaves the engine's declared ceiling
    public init(
        client: any JellyfinClientProtocol,
        item: MediaItem,
        userState: UserStateStore? = nil,
        mediaSourceId: String? = nil,
        streamingBitrateCap: Int?,
    ) {
        let engine = AVFoundationPlayerEngine(streamingBitrateCap: streamingBitrateCap)
        _playerEngine = State(initialValue: engine)
        _viewModel = State(initialValue: PlaybackViewModel(
            client: client,
            item: item,
            engine: engine,
            userState: userState,
            mediaSourceId: mediaSourceId,
        ))
    }

    public var body: some View {
        ZStack {
            Color.black

            switch viewModel.state {
            case .idle, .loading:
                ProgressView()
                    .scaleEffect(1.5)

            // A rebuild renders the same branch as playback on purpose: the
            // player stays mounted holding its last frame, and no loading
            // chrome goes over it. Splitting to a spinner here is what tore
            // the player view out from under AVKit's fullscreen window (#183).
            case .playing, .rebuilding:
                playerView

            case let .failed(message):
                errorView(message)

            case .finished:
                Color.black
            }

            // visionOS only. On tvOS the Up Next prompt is AVKit's native
            // content proposal, presented pre-roll inside the player's own
            // (focusable) hierarchy — the SwiftUI sibling here could never take
            // focus from a live `AVPlayerViewController` (#186). visionOS keeps
            // this overlay pending #182.
            #if os(visionOS)
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
            #endif
        }
        .ignoresSafeArea()
        .task {
            // SwiftUI cancels this task on disappear, but cancellation is
            // cooperative — an early dismiss can still resume this body after
            // `onDisappear` already ran its own fallback-ticket teardown. A
            // cancelled body must not register a session nothing will ever
            // finish: the coordinator has no unregister, so that ticket would
            // sit in `awaitPlaybackReporting`'s loop forever and wedge every
            // future drain. `onDisappear`'s `stop()` already covers teardown
            // for this case, idempotently.
            guard !Task.isCancelled else { return }
            // Registered before the player even starts, so no dismissal can
            // observe "nothing in flight" — SwiftUI guarantees no ordering
            // between `onDisappear` and a presenter's `onDismiss` (#236 § 6).
            playbackTicket = refreshCoordinator.registerPlayback()
            await viewModel.start()
        }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .finished {
                dismiss()
            }
        }
        .onDisappear {
            // Teardown is unconditional. An early dismiss can run this before
            // `.task` ever registered, and skipping `stop()` there would leak
            // the session and orphan a server-side transcode.
            //
            // The fallback still takes a ticket: merely posting would leave the
            // coordinator with nothing to await, and a refresh could then read
            // server state while this stop report was still landing — the exact
            // race this sequencing exists to remove.
            let ticket = playbackTicket ?? refreshCoordinator.registerPlayback()
            refreshCoordinator.finishPlayback(ticket, stop: Task { await viewModel.stop() })
        }
    }

    @ViewBuilder
    private var playerView: some View {
        #if canImport(UIKit)
            // The engine holds its player across a rebuild (it suspends
            // rather than tears down), so within `.playing` and `.rebuilding`
            // this is never nil and the representable is never unmounted
            // mid-session. That is the invariant #183 turns on: SwiftUI
            // removing this view while AVKit's fullscreen window is up leaves
            // the app's own window hidden with nothing to restore it.
            if let player = playerEngine.player {
                PlayerViewControllerRepresentable(
                    player: player,
                    audioStreams: viewModel.mediaSource?.audioStreams ?? [],
                    subtitleStreams: viewModel.offeredSubtitleStreams,
                    selectedAudioIndex: viewModel.selectedAudioStreamIndex,
                    selectedSubtitleIndex: viewModel.selectedSubtitleStreamIndex,
                    people: viewModel.castMembers,
                    isFavorite: viewModel.isFavorite,
                    outage: viewModel.outage,
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
                    // The player's own close control routes here rather than
                    // into AVKit's self-dismissal, which an embedded
                    // controller cannot perform. Tearing down the whole cover
                    // is the path that hands the window back — `onDisappear`
                    // still runs `stop()` and reports the final position.
                    onRequestDismiss: {
                        dismiss()
                    },
                    // tvOS Up Next: AVKit's content proposal reports the
                    // viewer's choice (or its countdown) through these (#186).
                    onAcceptUpNext: {
                        Task { await viewModel.playNextEpisodeNow() }
                    },
                    onDeclineUpNext: {
                        viewModel.declineUpNext()
                    },
                    onDeferUpNext: {
                        viewModel.deferUpNext()
                    },
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

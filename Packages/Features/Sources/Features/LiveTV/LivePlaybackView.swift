import DesignSystem
import JellyfinKit
import SwiftUI

/// Full-screen Live TV player: the system player on a channel's stream, with
/// the guide strip in its swipe-down panel.
///
/// tvOS only in practice. The view compiles for visionOS so the package
/// builds, but nothing there presents it.
struct LivePlaybackView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: LivePlaybackViewModel

    /// Focus for the error screen's Try Again, set explicitly because the
    /// failure can tear the focused player out from under the focus engine.
    @FocusState private var isRetryFocused: Bool

    private let client: any JellyfinClientProtocol
    private let guide: LiveGuideModel

    /// - Parameters:
    ///   - guide: the schedule the presenter already loaded; the player reads
    ///     what is on from it and offers its channels in the guide strip
    ///   - streamingBitrateCap: the viewer's streaming ceiling in bits per
    ///     second; nil leaves the engine's declared ceiling
    init(
        client: any JellyfinClientProtocol,
        channel: LiveChannel,
        guide: LiveGuideModel,
        streamingBitrateCap: Int?,
    ) {
        self.client = client
        self.guide = guide
        _viewModel = State(initialValue: LivePlaybackViewModel(
            client: client,
            channel: channel,
            capabilities: AVFoundationPlayerEngine.capabilities.cappedStreamingBitrate(to: streamingBitrateCap),
        ))
    }

    var body: some View {
        ZStack {
            Color.black

            switch viewModel.state {
            case .loading:
                ProgressView()
                    .scaleEffect(1.5)
            case .playing:
                playerView
            case let .failed(message):
                errorView(message)
            }
        }
        .ignoresSafeArea()
        .task {
            guard !Task.isCancelled else { return }
            await viewModel.start()
        }
        .task {
            // Keeps "on now" honest while watching: the player's title and
            // the strip follow the schedule as programmes change over.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await guide.tick()
            }
        }
        .onDisappear {
            Task { await viewModel.stop() }
        }
    }

    @ViewBuilder
    private var playerView: some View {
        #if canImport(UIKit)
            if let session = viewModel.session {
                let channel = viewModel.channel
                let program = guide.currentProgram(for: channel)
                LivePlayerRepresentable(
                    url: session.url,
                    nowPlaying: LiveTVText.nowPlayingItem(channel: channel, program: program),
                    artworkURL: client.liveArtworkURL(channel: channel, program: program, maxWidth: 600),
                    guide: guide,
                    client: client,
                    channelId: channel.id,
                    onSelectChannel: { picked in
                        Task { await viewModel.switchChannel(to: picked) }
                    },
                    onFailure: { url, reason in
                        viewModel.playerFailed(url: url, reason: reason)
                    },
                    onRequestDismiss: { dismiss() },
                )
            }
        #else
            Text("player.unsupportedPlatform", bundle: #bundle, comment: "Shown in place of the player on a platform without playback.")
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
        #endif
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: SpacingTokens.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.tertiary)

            Text("player.failed.title", bundle: #bundle, comment: "Heading shown when a video can't be played.")
                .jsStyle(.headline)
                .foregroundStyle(theme.primary)

            Text(message)
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SpacingTokens.xxl)

            HStack(spacing: SpacingTokens.md) {
                Button(LocalizedStringResource("player.failed.tryAgain", bundle: #bundle, comment: "Button that retries playback after it failed.")) {
                    Task { await viewModel.retry() }
                }
                .jsStyle(.body)
                .focused($isRetryFocused)

                Button(LocalizedStringResource("common.close", bundle: #bundle, comment: "Button that dismisses the current overlay or screen.")) {
                    dismiss()
                }
                .jsStyle(.body)
            }
        }
        .onAppear { isRetryFocused = true }
    }
}

#if canImport(UIKit)
    import AVKit

    /// The system player on one live stream.
    ///
    /// Owns its `AVPlayer` outright rather than going through
    /// `AVFoundationPlayerEngine`: that engine's resume seeks, chapter
    /// markers, Up Next and first-frame watchdog all assume an item with a
    /// length.
    private struct LivePlayerRepresentable: UIViewControllerRepresentable {
        let url: URL
        let nowPlaying: MediaItem
        let artworkURL: URL?
        let guide: LiveGuideModel
        let client: any JellyfinClientProtocol
        let channelId: String
        let onSelectChannel: (LiveChannel) -> Void
        let onFailure: (URL, String?) -> Void
        let onRequestDismiss: () -> Void

        @MainActor
        final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
            let player = AVPlayer()
            var loadedURL: URL?
            var statusObservation: NSKeyValueObservation?
            var nowPlaying: MediaItem?
            var artworkURL: URL?
            var artworkData: Data?
            var artworkTask: Task<Void, Never>?
            var onFailure: (URL, String?) -> Void = { _, _ in }
            var onRequestDismiss: () -> Void = {}

            func load(_ url: URL) {
                let item = AVPlayerItem(url: url)
                statusObservation = item.observe(\.status) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let reason = item.error?.localizedDescription
                    Task { @MainActor in
                        self?.onFailure(url, reason)
                    }
                }
                loadedURL = url
                player.replaceCurrentItem(with: item)
                applyMetadata()
                player.play()
            }

            /// The stream carries none of the programme's details, so the
            /// player's title view and Info tab are filled from the guide.
            func applyMetadata() {
                guard let nowPlaying else { return }
                player.currentItem?.externalMetadata = PlayerMetadataFactory.externalMetadata(
                    for: nowPlaying,
                    artworkData: artworkData,
                )
            }

            func loadArtwork(from url: URL?) {
                artworkURL = url
                artworkData = nil
                artworkTask?.cancel()
                guard let url else { return }
                artworkTask = Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
                    self?.artworkData = data
                    self?.applyMetadata()
                }
            }

            func tearDown() {
                artworkTask?.cancel()
                statusObservation = nil
                player.pause()
                player.replaceCurrentItem(with: nil)
            }

            #if os(visionOS)
                func playerViewController(
                    _: AVPlayerViewController,
                    willEndFullScreenPresentationWithAnimationCoordinator _: UIViewControllerTransitionCoordinator,
                ) {
                    onRequestDismiss()
                }
            #endif
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            let coordinator = context.coordinator
            controller.player = coordinator.player
            controller.delegate = coordinator
            // A live stream has nothing to scrub: there is no start to go
            // back to and no end to skip toward.
            controller.requiresLinearPlayback = true
            // Built once. AVKit re-lays out its tabs whenever the array is
            // reassigned, and the strip reads the guide itself, so it stays
            // current without being replaced.
            controller.customInfoViewControllers = [
                LiveGuideStripViewController(
                    guide: guide,
                    client: client,
                    channelId: channelId,
                    onSelect: onSelectChannel,
                ),
            ]
            sync(coordinator)
            return controller
        }

        func updateUIViewController(_: AVPlayerViewController, context: Context) {
            sync(context.coordinator)
        }

        static func dismantleUIViewController(_: AVPlayerViewController, coordinator: Coordinator) {
            coordinator.tearDown()
        }

        private func sync(_ coordinator: Coordinator) {
            coordinator.onFailure = onFailure
            coordinator.onRequestDismiss = onRequestDismiss
            let metadataChanged = coordinator.nowPlaying != nowPlaying
            coordinator.nowPlaying = nowPlaying
            if coordinator.loadedURL != url {
                coordinator.load(url)
            } else if metadataChanged {
                coordinator.applyMetadata()
            }
            if coordinator.artworkURL != artworkURL {
                coordinator.loadArtwork(from: artworkURL)
            }
        }
    }

    /// The player's "Guide" info tab: every channel with what it is showing
    /// now and next. Selecting one switches channel without leaving the player.
    private final class LiveGuideStripViewController: UIHostingController<LiveGuideStrip> {
        init(
            guide: LiveGuideModel,
            client: any JellyfinClientProtocol,
            channelId: String,
            onSelect: @escaping (LiveChannel) -> Void,
        ) {
            super.init(rootView: LiveGuideStrip(guide: guide, client: client, channelId: channelId, onSelect: onSelect))
            // AVKit reads the title for the tab label at attach time
            title = String(localized: "liveTV.player.tab.guide", bundle: #bundle, comment: "Player info-panel tab listing live TV channels and what each is showing.")
            preferredContentSize = CGSize(width: 960, height: 360)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        @MainActor dynamic required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    struct LiveGuideStrip: View {
        let guide: LiveGuideModel
        let client: (any JellyfinClientProtocol)?
        /// The channel being watched, where focus starts
        let channelId: String
        let onSelect: (LiveChannel) -> Void

        @FocusState private var focus: ShelfFocusID?

        private static let row = "liveGuideStrip"

        var body: some View {
            ScrollView(.horizontal) {
                // Not lazy: default focus has to find the watched channel's
                // card, which a lazy stack may not have built yet.
                HStack(alignment: .top, spacing: SpacingTokens.lg) {
                    ForEach(guide.channels) { channel in
                        LiveChannelCard(
                            channel: channel,
                            program: guide.currentProgram(for: channel),
                            now: guide.now,
                            secondLine: .channelAndNext(guide.nextProgram(for: channel)),
                            client: client,
                            width: 300,
                            focusBinding: $focus,
                            focusID: ShelfFocusID(row: Self.row, item: channel.id),
                            onPlay: { onSelect(channel) },
                        )
                    }
                }
                .padding(.horizontal, SpacingTokens.xl)
                .padding(.vertical, SpacingTokens.lg)
            }
            .scrollClipDisabled()
            .defaultFocus($focus, ShelfFocusID(row: Self.row, item: channelId))
            .withThemeEnvironment()
        }
    }
#endif

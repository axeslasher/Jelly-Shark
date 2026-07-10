import AVFoundation
import Foundation
import Observation
import JellyfinKit

/// View model for video playback
///
/// Owns the AVPlayer, drives playback state, reports progress to the
/// Jellyfin server, and handles next-episode autoplay. All state is
/// MainActor-confined because AVPlayer and KVO tokens are not Sendable.
@Observable
@MainActor
public final class PlaybackViewModel {
    /// Playback lifecycle state
    public enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
        case finished
    }

    // MARK: - Observable State

    /// Current playback state
    public private(set) var state: State = .idle

    /// The player, available once loading succeeds
    public private(set) var player: AVPlayer?

    /// The media source being played
    public private(set) var mediaSource: MediaSource?

    /// The item being played (updates when autoplay advances to the next episode)
    public private(set) var item: MediaItem

    /// The next episode, set at end of playback to drive the Up Next overlay
    public private(set) var nextEpisode: MediaItem?

    /// Currently selected audio stream index
    public private(set) var selectedAudioStreamIndex: Int?

    /// Currently selected subtitle stream index (nil = off)
    public private(set) var selectedSubtitleStreamIndex: Int?

    // MARK: - Private

    private let client: any JellyfinClientProtocol
    private let progressInterval: Duration
    private var playSessionId: String?
    private var playMethod: PlayMethod = .transcode
    private var progressTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var hasStopped = false

    // MARK: - Initialization

    /// - Parameters:
    ///   - client: The authenticated Jellyfin client
    ///   - item: The item to play
    ///   - progressInterval: How often to report progress (injectable for tests)
    public init(
        client: any JellyfinClientProtocol,
        item: MediaItem,
        progressInterval: Duration = .seconds(10)
    ) {
        self.client = client
        self.item = item
        self.progressInterval = progressInterval
    }

    // MARK: - Lifecycle

    /// Load the stream and begin playback (resuming from a saved position if any)
    public func start() async {
        state = .loading
        hasStopped = false

        let resumeTicks = item.userData?.playbackPositionTicks ?? 0

        do {
            let session = try await client.getPlaybackInfo(
                itemId: item.id,
                startTimeTicks: resumeTicks > 0 ? resumeTicks : nil,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex
            )

            guard let source = session.defaultMediaSource else {
                state = .failed("No playable media sources for this item")
                return
            }

            playSessionId = session.playSessionId
            mediaSource = source
            if selectedAudioStreamIndex == nil {
                selectedAudioStreamIndex = source.defaultAudioStreamIndex
            }

            let resolution = try client.resolveStream(
                for: source,
                parameters: StreamParameters(
                    itemId: item.id,
                    mediaSourceId: source.id,
                    playSessionId: playSessionId,
                    audioStreamIndex: selectedAudioStreamIndex,
                    subtitleStreamIndex: selectedSubtitleStreamIndex
                )
            )
            playMethod = resolution.playMethod

            await beginPlayback(url: resolution.url, resumeTicks: resumeTicks)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop playback, report the final position, and tear down. Idempotent.
    public func stop() async {
        guard !hasStopped else { return }
        hasStopped = true

        let positionTicks = currentPositionTicks()

        progressTask?.cancel()
        progressTask = nil
        removeEndObserver()
        timeControlObservation?.invalidate()
        timeControlObservation = nil

        player?.pause()
        player = nil

        // Telemetry must never block teardown
        try? await client.reportPlaybackStopped(
            itemId: item.id,
            mediaSourceId: mediaSource?.id,
            playSessionId: playSessionId,
            positionTicks: positionTicks
        )
    }

    // MARK: - Track Selection

    /// Switch to a different audio stream (rebuilds the stream, preserving position)
    public func selectAudioStream(index: Int) async {
        guard index != selectedAudioStreamIndex else { return }
        selectedAudioStreamIndex = index
        await rebuildStream()
    }

    /// Switch subtitles to the given stream index, or nil to turn them off
    public func selectSubtitleStream(index: Int?) async {
        guard index != selectedSubtitleStreamIndex else { return }
        selectedSubtitleStreamIndex = index
        await rebuildStream()
    }

    // MARK: - Next Episode

    /// Start the queued next episode immediately
    public func playNextEpisodeNow() async {
        guard let next = nextEpisode else { return }
        nextEpisode = nil

        // Close out the finished episode's session before starting the next
        await stop()

        item = next
        selectedAudioStreamIndex = nil
        selectedSubtitleStreamIndex = nil
        await start()
    }

    /// Dismiss the Up Next overlay and end the session
    public func cancelAutoplay() {
        nextEpisode = nil
        state = .finished
    }

    // MARK: - Playback Internals

    private func beginPlayback(url: URL, resumeTicks: Int64) async {
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player

        if resumeTicks > 0 {
            let seconds = PlaybackTicks.seconds(fromTicks: resumeTicks)
            await player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .positiveInfinity
            )
        }

        player.play()
        state = .playing

        try? await client.reportPlaybackStart(
            itemId: item.id,
            mediaSourceId: mediaSource?.id,
            playSessionId: playSessionId,
            positionTicks: resumeTicks,
            playMethod: playMethod,
            audioStreamIndex: selectedAudioStreamIndex,
            subtitleStreamIndex: selectedSubtitleStreamIndex
        )

        startProgressReporting()
        observeTimeControlStatus(of: player)
        observeEnd(of: playerItem)
    }

    private func rebuildStream() async {
        guard player != nil else { return }

        let positionTicks = currentPositionTicks()

        progressTask?.cancel()
        removeEndObserver()
        timeControlObservation?.invalidate()
        player?.pause()
        player = nil

        state = .loading

        do {
            let session = try await client.getPlaybackInfo(
                itemId: item.id,
                startTimeTicks: positionTicks > 0 ? positionTicks : nil,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex
            )

            guard let source = session.defaultMediaSource else {
                state = .failed("No playable media sources for this item")
                return
            }

            playSessionId = session.playSessionId
            mediaSource = source

            let resolution = try client.resolveStream(
                for: source,
                parameters: StreamParameters(
                    itemId: item.id,
                    mediaSourceId: source.id,
                    playSessionId: playSessionId,
                    audioStreamIndex: selectedAudioStreamIndex,
                    subtitleStreamIndex: selectedSubtitleStreamIndex
                )
            )
            playMethod = resolution.playMethod

            await beginPlayback(url: resolution.url, resumeTicks: positionTicks)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startProgressReporting() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.progressInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.reportProgress()
            }
        }
    }

    private func observeTimeControlStatus(of player: AVPlayer) {
        timeControlObservation?.invalidate()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor [weak self] in
                await self?.reportProgress()
            }
        }
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handlePlaybackEnded()
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    func handlePlaybackEnded() async {
        if item.type == .episode,
           let next = try? await client.getNextEpisode(after: item) {
            nextEpisode = next
        } else {
            await stop()
            state = .finished
        }
    }

    private func reportProgress() async {
        guard let player, !hasStopped else { return }

        try? await client.reportPlaybackProgress(
            itemId: item.id,
            mediaSourceId: mediaSource?.id,
            playSessionId: playSessionId,
            positionTicks: currentPositionTicks(),
            playMethod: playMethod,
            isPaused: player.timeControlStatus == .paused
        )
    }

    private func currentPositionTicks() -> Int64 {
        guard let player else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return PlaybackTicks.ticks(fromSeconds: seconds)
    }
}

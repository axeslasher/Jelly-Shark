import AVFoundation
import Foundation
import JellyfinKit
import Observation
import OSLog

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

    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let client: any JellyfinClientProtocol
    private let progressInterval: Duration
    private var playSessionId: String?
    private var playMethod: PlayMethod = .transcode
    private var progressTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var hasStopped = false

    /// Whether the current stream has the selected subtitle burned into the
    /// video, in which case no legible rendition exists to toggle
    private var sessionUsesBurnIn = false

    /// The current item's legible media-selection group, once loaded
    private var legibleGroup: AVMediaSelectionGroup?

    /// The legible group's options distilled for matching. Internal (not
    /// private) so tests can seed it without a real HLS asset.
    var legibleOptions: [LegibleOption] = []

    private var mediaSelectionTask: Task<Void, Never>?

    // MARK: - Initialization

    /// - Parameters:
    ///   - client: The authenticated Jellyfin client
    ///   - item: The item to play
    ///   - progressInterval: How often to report progress (injectable for tests)
    public init(
        client: any JellyfinClientProtocol,
        item: MediaItem,
        progressInterval: Duration = .seconds(10),
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
                subtitleStreamIndex: selectedSubtitleStreamIndex,
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
            // Seed the server-side default subtitle (forced tracks, user
            // profile preferences) only on fresh starts: an explicit "off"
            // mid-session must survive rebuilds, and autoplay resets the
            // selection before calling start() so each episode reseeds.
            if selectedSubtitleStreamIndex == nil {
                selectedSubtitleStreamIndex = source.defaultSubtitleStreamIndex
            }

            let resolution = try client.resolveStream(
                for: source,
                parameters: StreamParameters(
                    itemId: item.id,
                    mediaSourceId: source.id,
                    playSessionId: playSessionId,
                    audioStreamIndex: selectedAudioStreamIndex,
                    subtitleStreamIndex: selectedSubtitleStreamIndex,
                ),
            )
            playMethod = resolution.playMethod
            sessionUsesBurnIn = source.subtitleRequiresBurnIn(at: selectedSubtitleStreamIndex)
            logResolution(resolution, source: source, context: "start")

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
        clearMediaSelectionState()

        player?.pause()
        player = nil

        // Telemetry must never block teardown
        do {
            try await client.reportPlaybackStopped(
                itemId: item.id,
                mediaSourceId: mediaSource?.id,
                playSessionId: playSessionId,
                positionTicks: positionTicks,
            )
            Self.logger.info("[report] stopped ok \"\(self.item.name, privacy: .public)\" pos=\(positionTicks)")
        } catch {
            Self.logger.error("[report] stopped FAILED \"\(self.item.name, privacy: .public)\" pos=\(positionTicks): \(error, privacy: .public)")
        }
    }

    // MARK: - Track Selection

    /// Switch to a different audio stream (rebuilds the stream, preserving position)
    public func selectAudioStream(index: Int) async {
        guard index != selectedAudioStreamIndex else { return }
        selectedAudioStreamIndex = index
        await rebuildStream()
    }

    /// Switch subtitles to the given stream index, or nil to turn them off.
    ///
    /// Within an HLS session the master playlist already carries every
    /// deliverable text rendition, so most switches only need a media
    /// selection on the current player item — no reload. Rebuilding is
    /// reserved for transitions the playlist can't express: entering or
    /// leaving burn-in, and targets missing from the loaded renditions.
    public func selectSubtitleStream(index: Int?) async {
        guard index != selectedSubtitleStreamIndex else { return }

        let targetMatched = mediaSource?.subtitleStream(at: index)
            .flatMap { SubtitleOptionMatcher.match($0, in: legibleOptions) } != nil
        let canSwitchInPlace = Self.canSwitchSubtitlesInPlace(
            hasPlayer: player != nil,
            currentMethod: playMethod,
            sessionUsesBurnIn: sessionUsesBurnIn,
            targetRequiresBurnIn: mediaSource?.subtitleRequiresBurnIn(at: index) ?? false,
            turningOff: index == nil,
            targetMatched: targetMatched,
        )

        selectedSubtitleStreamIndex = index

        if canSwitchInPlace {
            applySubtitleSelection()
            Self.logger.info("""
            [subtitle] in-place switch "\(self.item.name, privacy: .public)" → \
            \(index.map(String.init) ?? "off", privacy: .public)
            """)
            // Keep the server's session view current without a fake start
            // report: progress now carries the stream indices
            await reportProgress()
        } else {
            await rebuildStream()
        }
    }

    /// Whether a subtitle change can be satisfied by selecting a rendition
    /// on the current player item instead of rebuilding the stream.
    /// Pure so the decision matrix is unit-testable without AVPlayer.
    static func canSwitchSubtitlesInPlace(
        hasPlayer: Bool,
        currentMethod: PlayMethod,
        sessionUsesBurnIn: Bool,
        targetRequiresBurnIn: Bool,
        turningOff: Bool,
        targetMatched: Bool,
    ) -> Bool {
        // Direct play has no renditions to select; a burned-in track can
        // only be added or removed by re-encoding
        guard hasPlayer, currentMethod != .directPlay,
              !sessionUsesBurnIn, !targetRequiresBurnIn
        else {
            return false
        }
        return turningOff || targetMatched
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
        // The master playlist marks every text rendition AUTOSELECT=YES;
        // left on, AVPlayer would enable subtitles from system accessibility
        // preferences behind the app's explicit selection state
        player.appliesMediaSelectionCriteriaAutomatically = false
        self.player = player

        loadLegibleOptions(for: playerItem)

        if resumeTicks > 0 {
            let seconds = PlaybackTicks.seconds(fromTicks: resumeTicks)
            await player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .positiveInfinity,
            )
        }

        player.play()
        state = .playing

        do {
            try await client.reportPlaybackStart(
                itemId: item.id,
                mediaSourceId: mediaSource?.id,
                playSessionId: playSessionId,
                positionTicks: resumeTicks,
                playMethod: playMethod,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex,
            )
            Self.logger.info("[report] start ok \"\(self.item.name, privacy: .public)\" pos=\(resumeTicks) method=\(String(describing: self.playMethod), privacy: .public)")
        } catch {
            Self.logger.error("[report] start FAILED \"\(self.item.name, privacy: .public)\" pos=\(resumeTicks): \(error, privacy: .public)")
        }

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
        clearMediaSelectionState()
        player?.pause()
        player = nil

        state = .loading

        do {
            let session = try await client.getPlaybackInfo(
                itemId: item.id,
                startTimeTicks: positionTicks > 0 ? positionTicks : nil,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex,
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
                    subtitleStreamIndex: selectedSubtitleStreamIndex,
                ),
            )
            playMethod = resolution.playMethod
            sessionUsesBurnIn = source.subtitleRequiresBurnIn(at: selectedSubtitleStreamIndex)
            logResolution(resolution, source: source, context: "rebuild")

            await beginPlayback(url: resolution.url, resumeTicks: positionTicks)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Subtitle Media Selection

    /// Load the legible group of the freshly created player item so text
    /// renditions can be selected in place. Direct play is skipped: it has
    /// no renditions, and its embedded defaults are left to the player.
    private func loadLegibleOptions(for playerItem: AVPlayerItem) {
        mediaSelectionTask?.cancel()
        legibleGroup = nil
        legibleOptions = []
        guard playMethod != .directPlay else { return }

        mediaSelectionTask = Task { [weak self] in
            guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible),
                  !Task.isCancelled
            else { return }
            self?.legibleGroupDidLoad(group, for: playerItem)
        }
    }

    private func legibleGroupDidLoad(_ group: AVMediaSelectionGroup, for playerItem: AVPlayerItem) {
        // A rebuild may have replaced the player while the group loaded
        guard player?.currentItem === playerItem else { return }

        legibleGroup = group
        legibleOptions = group.options.enumerated().map { position, option in
            LegibleOption(
                position: position,
                displayName: option.displayName,
                languageTag: option.extendedLanguageTag,
            )
        }
        Self.logger.debug("[subtitle] legible options loaded: \(self.legibleOptions.count)")
        applySubtitleSelection()
    }

    /// Point the player item's legible selection at the chosen subtitle
    /// stream — or clear it, so an AUTOSELECT rendition can't stay active
    /// against an explicit "off" or a burned-in track
    private func applySubtitleSelection() {
        guard let legibleGroup, let playerItem = player?.currentItem else { return }

        if !sessionUsesBurnIn,
           let target = mediaSource?.subtitleStream(at: selectedSubtitleStreamIndex),
           let position = SubtitleOptionMatcher.match(target, in: legibleOptions),
           legibleGroup.options.indices.contains(position)
        {
            playerItem.select(legibleGroup.options[position], in: legibleGroup)
        } else {
            playerItem.select(nil, in: legibleGroup)
        }
    }

    private func clearMediaSelectionState() {
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        legibleGroup = nil
        legibleOptions = []
    }

    /// One line per stream resolution so a play session's delivery decisions
    /// can be read back from the console (filter the Xcode console or
    /// `log stream` on the "Playback" category).
    private func logResolution(_ resolution: StreamResolution, source: MediaSource, context: String) {
        Self.logger.info("""
        [\(context, privacy: .public)] "\(self.item.name, privacy: .public)" → \
        \(String(describing: resolution.playMethod), privacy: .public) \
        (container=\(source.container ?? "?", privacy: .public) \
        directPlay=\(source.supportsDirectPlay) directStream=\(source.supportsDirectStream) \
        audio=\(self.selectedAudioStreamIndex.map(String.init) ?? "default", privacy: .public) \
        subtitle=\(self.selectedSubtitleStreamIndex.map(String.init) ?? "off", privacy: .public)) \
        url=\(Self.sanitizedForLog(resolution.url), privacy: .public)
        """)
    }

    /// The stream URL with the access token blanked, safe for console logs
    private static func sanitizedForLog(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<unparseable>"
        }
        components.queryItems = components.queryItems?.map { item in
            item.name == "api_key" ? URLQueryItem(name: "api_key", value: "REDACTED") : item
        }
        return components.url?.absoluteString ?? "<unparseable>"
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
            queue: .main,
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
           let next = try? await client.getNextEpisode(after: item)
        {
            nextEpisode = next
        } else {
            await stop()
            state = .finished
        }
    }

    private func reportProgress() async {
        guard let player, !hasStopped else { return }

        let positionTicks = currentPositionTicks()
        do {
            try await client.reportPlaybackProgress(
                itemId: item.id,
                mediaSourceId: mediaSource?.id,
                playSessionId: playSessionId,
                positionTicks: positionTicks,
                playMethod: playMethod,
                isPaused: player.timeControlStatus == .paused,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex,
            )
            // Success at debug level — one line every heartbeat is only
            // interesting when actively diagnosing
            Self.logger.debug("[report] progress ok \"\(self.item.name, privacy: .public)\" pos=\(positionTicks)")
        } catch {
            Self.logger.error("[report] progress FAILED \"\(self.item.name, privacy: .public)\" pos=\(positionTicks): \(error, privacy: .public)")
        }
    }

    private func currentPositionTicks() -> Int64 {
        guard let player else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return PlaybackTicks.ticks(fromSeconds: seconds)
    }
}

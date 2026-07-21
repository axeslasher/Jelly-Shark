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

    /// Cast and crew for the player's info tab (resolved during `start()` —
    /// the launching item often lacks the People field)
    public private(set) var castMembers: [CastMember] = []

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

    /// The current item's audible media-selection group, once loaded
    private var audibleGroup: AVMediaSelectionGroup?

    /// The audible group's options distilled for matching. Internal (not
    /// private) so tests can seed it without a real asset.
    var audibleOptions: [AudibleOption] = []

    private var mediaSelectionTask: Task<Void, Never>?

    /// Whether native-picker reconciliation may run. Disarmed on every new
    /// player item until the app's own initial selection pass completes:
    /// AVFoundation announces its own default picks while the item loads,
    /// and adopting those as user intent would feed them back into
    /// `applySubtitleSelection` against an explicit "off".
    private var mediaSelectionReconcileArmed = false

    private var mediaSelectionObserver: NSObjectProtocol?

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

            // Playback extras: resolve trickplay and chapters up front so
            // beginPlayback can interpose the I-frame rendition and attach
            // navigation markers. Trickplay is fetched even for direct play —
            // a mid-session track switch can rebuild onto HLS. Absent data or
            // a failed fetch just means scrubbing stays blind and the
            // chapter panel stays empty, exactly as before.
            let extras = await (try? client.getPlaybackExtras(itemId: item.id)) ?? nil
            trickplayInfo = extras?.trickplay?.info(forMediaSourceId: source.id)
            chapters = extras?.chapters ?? []
            // The launching item is the fallback: shelf items rarely carry
            // People, but a detail-page item does even when the fetch fails
            let extrasPeople = extras?.people ?? []
            castMembers = extrasPeople.isEmpty ? (item.people ?? []) : extrasPeople

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
        localServer?.stop()
        localServer = nil
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil

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

    /// Headshot URL for the player's cast tab (the view has no client access)
    public func headshotURL(for member: CastMember) -> URL? {
        client.headshotURL(for: member)
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
    /// Switching between two text subtitles is a media selection on the
    /// current player item — the loaded master playlist already carries both
    /// renditions, so no reload is needed. Everything else rebuilds: entering
    /// or leaving burn-in, targets missing from the loaded renditions, and
    /// turning subtitles on or off at all, which changes the segment
    /// container and video codec together.
    public func selectSubtitleStream(index: Int?) async {
        guard index != selectedSubtitleStreamIndex else { return }

        let targetMatched = mediaSource?.subtitleStream(at: index)
            .flatMap { SubtitleOptionMatcher.match($0, in: legibleOptions) } != nil
        let canSwitchInPlace = Self.canSwitchSubtitlesInPlace(
            hasPlayer: player != nil,
            currentMethod: playMethod,
            sessionUsesBurnIn: sessionUsesBurnIn,
            targetRequiresBurnIn: mediaSource?.subtitleRequiresBurnIn(at: index) ?? false,
            currentlyDeliveringTextSubtitle: selectedSubtitleStreamIndex != nil,
            targetMatched: targetMatched,
        )

        selectedSubtitleStreamIndex = index

        if canSwitchInPlace {
            if applySubtitleSelection() {
                Self.logger.info("""
                [subtitle] in-place switch "\(self.item.name, privacy: .public)" → \
                \(index.map(String.init) ?? "off", privacy: .public)
                """)
            } else {
                // canSwitchInPlace implied a live item, but the player can
                // be torn down between the decision and the selection
                Self.logger.warning("""
                [subtitle] in-place switch to \
                \(index.map(String.init) ?? "off", privacy: .public) had no live item to apply to
                """)
            }
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
    ///
    /// Only a switch *between* text subtitles qualifies — the stream must be
    /// carrying one before and after. Its shape depends on that: TS/H.264
    /// while a WebVTT rendition rides along (Jellyfin's VTT carries
    /// `X-TIMESTAMP-MAP=MPEGTS:900000`, which only lines up against TS), and
    /// fMP4 (HEVC passthrough allowed) otherwise. Turning a subtitle on or
    /// off crosses that line, and the loaded player item cannot express the
    /// change.
    ///
    /// `targetMatched` alone is not enough to tell them apart. The master
    /// playlist advertises every text rendition whether or not one was
    /// requested, so a target matches even on an unsubtitled fMP4 stream —
    /// and selecting it there renders every cue exactly 10s late. Hence the
    /// explicit `currentlyDeliveringTextSubtitle` gate. At the call site that
    /// parameter is merely "a subtitle index is selected" — also true of a
    /// burned-in track; the burn-in guards below are what narrow it to text
    /// delivery.
    static func canSwitchSubtitlesInPlace(
        hasPlayer: Bool,
        currentMethod: PlayMethod,
        sessionUsesBurnIn: Bool,
        targetRequiresBurnIn: Bool,
        currentlyDeliveringTextSubtitle: Bool,
        targetMatched: Bool,
    ) -> Bool {
        // Direct play has no renditions to select; a burned-in track can
        // only be added or removed by re-encoding
        guard hasPlayer, currentMethod != .directPlay,
              !sessionUsesBurnIn, !targetRequiresBurnIn
        else {
            return false
        }
        // Both ends must be a text subtitle: turning off never matches, and
        // turning on has no rendition-bearing stream to switch within
        return currentlyDeliveringTextSubtitle && targetMatched
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
        let playerItem = await makePlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        // The master playlist marks every text rendition AUTOSELECT=YES;
        // left on, AVPlayer would enable subtitles from system accessibility
        // preferences behind the app's explicit selection state
        player.appliesMediaSelectionCriteriaAutomatically = false
        self.player = player

        applyPlayerMetadata(to: playerItem)
        loadMediaSelectionOptions(for: playerItem)

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
        observeMediaSelection(of: playerItem)
    }

    /// The trickplay resolution for the current item's media source, when the
    /// server has seek-preview data (resolved during `start()`)
    private var trickplayInfo: TrickplayInfo?

    /// The current item's chapters (resolved during `start()`), empty when
    /// the server reports none
    private var chapters: [Chapter] = []

    /// The loopback server interposing the master playlist for the current
    /// player item (trickplay + subtitle-playlist rewriting); nil on direct
    /// play or when the listener could not start
    private var localServer: PlaybackLocalServer?

    /// In-flight artwork enrichment (chapter thumbnails + poster) for the
    /// current player item
    private var metadataArtworkTask: Task<Void, Never>?

    /// Attach chapter markers and Info-tab metadata to a fresh player item,
    /// then enrich both with artwork off the critical path
    ///
    /// HLS remux/transcode streams carry none of the source file's embedded
    /// metadata, so the Chapters panel and Info tab are reconstructed from
    /// Jellyfin data. Text lands synchronously — chapters are usable as soon
    /// as the transport bar appears — and thumbnails upgrade the markers in
    /// one re-set when their fetches finish.
    private func applyPlayerMetadata(to playerItem: AVPlayerItem) {
        playerItem.externalMetadata = PlayerMetadataFactory.externalMetadata(for: item)

        #if os(tvOS)
            if let duration = itemDurationSeconds,
               let group = PlayerMetadataFactory.navigationMarkerGroup(
                   chapters: chapters,
                   durationSeconds: duration,
               )
            {
                playerItem.navigationMarkerGroups = [group]
            }
        #endif

        startMetadataEnrichment(for: playerItem)
    }

    private var itemDurationSeconds: Double? {
        item.runTimeTicks.map { PlaybackTicks.seconds(fromTicks: $0) }
    }

    private func startMetadataEnrichment(for playerItem: AVPlayerItem) {
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil

        let posterURL = client.posterURL(for: item)
        guard !chapters.isEmpty || posterURL != nil else { return }

        let chapters = chapters
        let info = trickplayInfo
        let itemId = item.id
        let mediaSourceId = mediaSource?.id
        let client = client

        metadataArtworkTask = Task { [weak self, weak playerItem] in
            let chapterArtwork = await ChapterArtworkLoader.loadArtwork(
                for: chapters,
                chapterImageURL: { chapter in
                    chapter.imageTag.map {
                        client.chapterImageURL(
                            itemId: itemId,
                            chapterIndex: chapter.imageIndex,
                            tag: $0,
                            maxWidth: 320,
                        )
                    }
                },
                trickplayInfo: info,
                trickplayTileURL: { tileIndex in
                    guard let info else { return nil }
                    return client.trickplayTileURL(
                        itemId: itemId,
                        width: info.widthKey,
                        tileIndex: tileIndex,
                        mediaSourceId: mediaSourceId,
                    )
                },
            )
            let posterData = await ChapterArtworkLoader.imageData(from: posterURL)

            guard !Task.isCancelled, let self, let playerItem else { return }
            self.applyEnrichedMetadata(
                chapterArtwork: chapterArtwork,
                posterData: posterData,
                to: playerItem,
            )
        }
    }

    private func applyEnrichedMetadata(
        chapterArtwork: [Int: Data],
        posterData: Data?,
        to playerItem: AVPlayerItem,
    ) {
        // A rebuild or episode change may have swapped the item mid-fetch
        guard player?.currentItem === playerItem else { return }
        guard !chapterArtwork.isEmpty || posterData != nil else { return }

        playerItem.externalMetadata = PlayerMetadataFactory.externalMetadata(
            for: item,
            artworkData: posterData,
        )

        #if os(tvOS)
            if !chapterArtwork.isEmpty,
               let duration = itemDurationSeconds,
               let group = PlayerMetadataFactory.navigationMarkerGroup(
                   chapters: chapters,
                   durationSeconds: duration,
                   artwork: chapterArtwork,
               )
            {
                playerItem.navigationMarkerGroups = [group]
            }
        #endif
    }

    /// Build the player item: plain URL for direct play, and an interposed
    /// master serving the synthesized trickplay I-frame rendition for HLS
    /// sessions with seek-preview data
    private func makePlayerItem(url: URL) async -> AVPlayerItem {
        localServer?.stop()
        localServer = nil

        guard playMethod != .directPlay else {
            return AVPlayerItem(url: url)
        }

        let itemId = item.id
        let sourceId = mediaSource?.id
        let client = client
        let info = trickplayInfo
        let server = PlaybackLocalServer(originalMasterURL: url, info: info) { tileIndex in
            guard let info else { return nil }
            return client.trickplayTileURL(
                itemId: itemId,
                width: info.widthKey,
                tileIndex: tileIndex,
                mediaSourceId: sourceId,
            )
        }

        guard let interposedURL = await server.start() else {
            return AVPlayerItem(url: url)
        }
        localServer = server
        return AVPlayerItem(url: interposedURL)
    }

    private func rebuildStream() async {
        guard player != nil else { return }

        let positionTicks = currentPositionTicks()

        progressTask?.cancel()
        removeEndObserver()
        timeControlObservation?.invalidate()
        clearMediaSelectionState()
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil
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

    // MARK: - Media Selection

    /// Load the media-selection groups of the freshly created player item.
    ///
    /// The legible group backs in-place text-rendition selection, so it is
    /// skipped on direct play (no renditions; the embedded defaults are left
    /// to the player). The audible group exists purely for reconciling
    /// native-picker changes (#89) and loads everywhere — a direct-played
    /// file's embedded tracks are exactly what the native audio picker
    /// switches behind the app's back.
    private func loadMediaSelectionOptions(for playerItem: AVPlayerItem) {
        mediaSelectionTask?.cancel()
        legibleGroup = nil
        legibleOptions = []
        audibleGroup = nil
        audibleOptions = []
        mediaSelectionReconcileArmed = false

        mediaSelectionTask = Task { [weak self] in
            await self?.loadAudibleGroup(for: playerItem)
            if self?.playMethod != .directPlay {
                await self?.loadLegibleGroup(for: playerItem)
            }
            guard let self, !Task.isCancelled,
                  self.player?.currentItem === playerItem else { return }
            // Arm only once the app's own selection has been applied
            // (`legibleGroupDidLoad` → `applySubtitleSelection`); earlier
            // change notifications are AVFoundation's default picks, not
            // user intent
            self.mediaSelectionReconcileArmed = true
        }
    }

    private func loadAudibleGroup(for playerItem: AVPlayerItem) async {
        do {
            guard let group = try await playerItem.asset.loadMediaSelectionGroup(for: .audible) else {
                Self.logger.debug("[audio] stream carries no audible group")
                return
            }
            guard !Task.isCancelled, player?.currentItem === playerItem else { return }
            audibleGroup = group
            audibleOptions = group.options.enumerated().map { position, option in
                AudibleOption(
                    position: position,
                    displayName: option.displayName,
                    languageTag: option.extendedLanguageTag,
                )
            }
        } catch {
            Self.logger.warning("[audio] audible group load failed: \(error, privacy: .public)")
        }
    }

    private func loadLegibleGroup(for playerItem: AVPlayerItem) async {
        do {
            guard let group = try await playerItem.asset.loadMediaSelectionGroup(for: .legible) else {
                // Normal on a stream with no legible renditions
                Self.logger.debug("[subtitle] stream carries no legible group")
                return
            }
            guard !Task.isCancelled else { return }
            legibleGroupDidLoad(group, for: playerItem)
        } catch {
            // The root of the subtitle pipeline: if this load fails, no
            // rendition can ever be selected and every diagnostic
            // downstream is unreachable, so record the cause at a
            // persisted level
            Self.logger.warning("[subtitle] legible group load failed: \(error, privacy: .public)")
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
    /// - Returns: Whether a live player item was there to apply to
    @discardableResult
    private func applySubtitleSelection() -> Bool {
        guard let legibleGroup, let playerItem = player?.currentItem else { return false }

        if !sessionUsesBurnIn,
           let target = mediaSource?.subtitleStream(at: selectedSubtitleStreamIndex),
           let position = SubtitleOptionMatcher.match(target, in: legibleOptions),
           legibleGroup.options.indices.contains(position)
        {
            playerItem.select(legibleGroup.options[position], in: legibleGroup)
            Self.logger.debug("""
            [subtitle] selected rendition \(position, privacy: .public) \
            for stream \(self.selectedSubtitleStreamIndex.map(String.init) ?? "off", privacy: .public)
            """)
        } else if !sessionUsesBurnIn, let index = selectedSubtitleStreamIndex {
            playerItem.select(nil, in: legibleGroup)
            // A selected stream with no matching rendition is a failure, not
            // an "off": the menu shows subtitles on while no cues render.
            // Warning-level so a field sysdiagnose records it — .debug is not
            // persisted to the log store
            let target = mediaSource?.subtitleStream(at: index)
            Self.logger.warning("""
            [subtitle] no rendition matched stream \(index, privacy: .public) \
            "\(target?.displayTitle ?? target?.language ?? "unknown", privacy: .public)" — \
            subtitles will not render (options: \
            \(self.legibleOptions.map(\.displayName).joined(separator: ", "), privacy: .public))
            """)
        } else {
            playerItem.select(nil, in: legibleGroup)
            Self.logger.debug("""
            [subtitle] cleared rendition (deliberate off, \
            burnIn=\(self.sessionUsesBurnIn, privacy: .public))
            """)
        }
        return true
    }

    private func clearMediaSelectionState() {
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        legibleGroup = nil
        legibleOptions = []
        audibleGroup = nil
        audibleOptions = []
        mediaSelectionReconcileArmed = false
        removeMediaSelectionObserver()
    }

    // MARK: - Native-Picker Reconciliation

    /// What a reconcile pass should do with one track type's stored index
    enum ReconcileDecision: Equatable {
        case noChange
        case update(Int?)
        /// A selection exists but no stream can be confidently matched;
        /// state is left untouched and the miss is logged
        case unmatched
    }

    private func observeMediaSelection(of playerItem: AVPlayerItem) {
        removeMediaSelectionObserver()
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: playerItem,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reconcileMediaSelection()
            }
        }
    }

    private func removeMediaSelectionObserver() {
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
        }
        mediaSelectionObserver = nil
    }

    /// Adopt a native-picker track change into view-model state.
    ///
    /// AVKit's transport-bar pickers flip renditions directly on the player
    /// item, bypassing `selectAudioStream`/`selectSubtitleStream` — without
    /// this, the app's menu checkmarks and playback reporting go stale
    /// (#89). Reconciliation is write-only: it never selects and never
    /// rebuilds, so the app's own programmatic selection echoes back here,
    /// finds state already matching, and stops — no feedback cycle is
    /// possible by construction.
    private func reconcileMediaSelection() async {
        guard mediaSelectionReconcileArmed,
              let playerItem = player?.currentItem else { return }
        let selection = playerItem.currentMediaSelection
        var changed = false

        if let group = legibleGroup {
            let position = selection.selectedMediaOption(in: group)
                .flatMap { group.options.firstIndex(of: $0) }
            let decision = Self.subtitleReconcileDecision(
                selectedPosition: position,
                currentIndex: selectedSubtitleStreamIndex,
                sessionUsesBurnIn: sessionUsesBurnIn,
                streams: mediaSource?.subtitleStreams ?? [],
                options: legibleOptions,
            )
            switch decision {
            case let .update(index):
                selectedSubtitleStreamIndex = index
                changed = true
                Self.logger.info("""
                [subtitle] reconciled native selection → \
                \(index.map(String.init) ?? "off", privacy: .public)
                """)
            case .unmatched:
                Self.logger.warning("""
                [subtitle] native selection at position \
                \(position.map(String.init) ?? "nil", privacy: .public) \
                matches no stream — menu and reporting may be stale
                """)
            case .noChange:
                break
            }
        }

        // A lone audible option is a muxed transcode rendition: the native
        // picker has nothing to offer, and its metadata (displayName
        // "Unknown", no language) matches no Jellyfin stream — reconciling
        // it would warn on every notification for a switch nobody can make
        if let group = audibleGroup, audibleOptions.count > 1 {
            let option = selection.selectedMediaOption(in: group)
                .flatMap { group.options.firstIndex(of: $0) }
                .flatMap { position in audibleOptions.first { $0.position == position } }
            let decision = Self.audioReconcileDecision(
                selectedOption: option,
                currentIndex: selectedAudioStreamIndex,
                streams: mediaSource?.audioStreams ?? [],
                options: audibleOptions,
            )
            switch decision {
            case let .update(index):
                // Direct write: reconcile must never route through
                // `selectAudioStream`, which would rebuild the stream the
                // native picker just switched in place
                selectedAudioStreamIndex = index
                changed = true
                Self.logger.info("""
                [audio] reconciled native selection → \
                \(index.map(String.init) ?? "default", privacy: .public)
                """)
            case .unmatched:
                Self.logger.warning("""
                [audio] native selection \
                "\(option?.displayName ?? "?", privacy: .public)" matches no \
                stream — menu and reporting may be stale
                """)
            case .noChange:
                break
            }
        }

        // One heartbeat so the server's session view follows the switch
        if changed {
            await reportProgress()
        }
    }

    /// Decide how a legible-selection change maps onto the stored subtitle
    /// index. Pure so the matrix is unit-testable without AVPlayer.
    static func subtitleReconcileDecision(
        selectedPosition: Int?,
        currentIndex: Int?,
        sessionUsesBurnIn: Bool,
        streams: [MediaStreamInfo],
        options: [LegibleOption],
    ) -> ReconcileDecision {
        // Burn-in renders inside the video; the legible selection carries
        // no user intent there
        guard !sessionUsesBurnIn else { return .noChange }

        guard let selectedPosition else {
            return currentIndex == nil ? .noChange : .update(nil)
        }

        // If the stored stream already explains the rendition on screen,
        // stop — the common echo of the app's own apply, and the safe
        // answer when the reverse match below would be ambiguous
        if let currentIndex,
           let current = streams.first(where: { $0.index == currentIndex }),
           SubtitleOptionMatcher.match(current, in: options) == selectedPosition
        {
            return .noChange
        }

        guard let index = SubtitleOptionMatcher.streamIndex(
            forSelectedPosition: selectedPosition,
            streams: streams,
            options: options,
        ) else { return .unmatched }
        return index == currentIndex ? .noChange : .update(index)
    }

    /// Decide how an audible-selection change maps onto the stored audio
    /// index. Pure so the matrix is unit-testable without AVPlayer.
    static func audioReconcileDecision(
        selectedOption: AudibleOption?,
        currentIndex: Int?,
        streams: [MediaStreamInfo],
        options: [AudibleOption],
    ) -> ReconcileDecision {
        // Audio is never legitimately deselected; a nil here is a loading
        // transient, not intent
        guard let selectedOption else { return .noChange }

        guard let index = AudioOptionMatcher.streamIndex(
            forSelectedOption: selectedOption,
            streams: streams,
            options: options,
        ) else { return .unmatched }
        return index == currentIndex ? .noChange : .update(index)
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

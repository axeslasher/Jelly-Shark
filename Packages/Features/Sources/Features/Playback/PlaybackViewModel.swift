import Foundation
import JellyfinKit
import Observation
import OSLog

/// View model for video playback: the session half of the player (#85).
///
/// Owns what is playing and why — stream resolution, track selection,
/// progress reporting to the Jellyfin server, delivery-failure policy, and
/// next-episode autoplay. Rendering and transport live behind
/// `PlayerEngine`; delivery (how the resolved URL reaches the engine)
/// behind `StreamDelivery`. All state is MainActor-confined.
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

    /// Favorite state the transport bar shows, read through the user-state
    /// overlay — the same authority the detail pages read, so a heart
    /// pressed anywhere agrees everywhere (#193).
    public var isFavorite: Bool {
        userState.resolve(item).userData?.isFavorite ?? false
    }

    // MARK: - Private

    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    private let client: any JellyfinClientProtocol
    private let engine: any PlayerEngine
    private let progressInterval: Duration

    /// The shared user-state overlay. A private fallback keeps the toggle
    /// and resolve semantics identical when the container constructs the
    /// model without one (previews, tests) — one code path, not two.
    private let userState: UserStateStore
    private var playSessionId: String?
    private var playMethod: PlayMethod = .transcode
    private var progressTask: Task<Void, Never>?
    private var hasStopped = false

    /// First-frame deadline for the current session (#151). The engine's
    /// failure events and this watchdog are the only routes a post-`play()`
    /// failure has into `state`; they are armed and torn down together.
    private var firstFrameWatchdog: Task<Void, Never>?

    /// Gate for the engine's `.deliveryFailed` events. The engine arms its
    /// observers inside `load`, but historically the view model attached
    /// them only after `play()` — this flag preserves that timing, and
    /// `armDeliveryFailureDetection` re-checks the engine's error so a
    /// failure from the gap still surfaces (the `.initial` KVO behavior).
    private var deliveryFailureEventsArmed = false

    /// Gate for transport/end/media-selection events, which historically
    /// attached only after the start report's network round trip — without
    /// it the play() ramp would emit progress heartbeats before the start
    /// report reaches the server.
    private var steadyStateEventsArmed = false

    /// Bumped per `engine.load`; async completions capture it and are
    /// dropped when a rebuild or autoplay has moved the session on
    private var sessionEpoch = 0

    /// Whether the current stream has the selected subtitle burned into the
    /// video, in which case no legible rendition exists to toggle
    private var sessionUsesBurnIn = false

    /// Whether native-picker reconciliation may run. Disarmed on every new
    /// stream until the engine reports its selection options loaded — a
    /// change notification arriving before then could not be mapped to a
    /// Jellyfin stream index.
    private var mediaSelectionReconcileArmed = false

    // MARK: - Initialization

    /// - Parameters:
    ///   - client: The authenticated Jellyfin client
    ///   - item: The item to play
    ///   - engine: The rendering/transport engine to drive
    ///   - progressInterval: How often to report progress (injectable for tests)
    init(
        client: any JellyfinClientProtocol,
        item: MediaItem,
        engine: any PlayerEngine,
        progressInterval: Duration = .seconds(10),
        userState: UserStateStore? = nil,
    ) {
        self.client = client
        self.item = item
        self.engine = engine
        self.progressInterval = progressInterval
        self.userState = userState ?? UserStateStore()
        engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }
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
                capabilities: engine.capabilities,
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
            // Seed the server default only when it is a burn-in track — the
            // app is the only thing that can honor those (the server must
            // composite them). A text default is deliberately NOT seeded:
            // AVKit owns text subtitles, and the master playlist's
            // DEFAULT=YES flag plus the viewer's system caption preference
            // decide auto-on natively. Seeding only on fresh starts keeps an
            // explicit mid-session "off" alive across rebuilds; autoplay
            // resets the selection so each episode reseeds.
            if selectedSubtitleStreamIndex == nil,
               source.subtitleRequiresBurnIn(at: source.defaultSubtitleStreamIndex)
            {
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
                capabilities: engine.capabilities,
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

            // Feed the server's fresh user data into the shared overlay
            // (the extras fetch isn't a MediaItem fetch, so the caching
            // client's ingestion never sees it). `item` itself stays the
            // launch site's copy: `retry()` re-reads the resume position
            // from it, and taking the server's would make Try Again resume
            // somewhere the first press did not. Display state — the
            // transport bar's heart included (#189) — reads through the
            // overlay, so the stale copy misleads nothing.
            if let freshUserData = extras?.userData {
                var fresh = item
                fresh.userData = freshUserData
                userState.ingest(serverItems: [fresh])
            }

            await beginPlayback(resolution: resolution, resumeTicks: resumeTicks)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Abandon a failed session and start the same item over, in place.
    ///
    /// A full `stop()` first, not a bare `start()`: `failDelivery` leaves the
    /// paused engine and — on a transcode — the server-side ffmpeg alive on
    /// purpose, so the failed session stays diagnosable while the error screen
    /// is up. Retrying without tearing that down would orphan the encode and
    /// stack a second one on top of it. `stop()` is idempotent and
    /// `failDelivery` does not set `hasStopped`, so this runs the real
    /// teardown, and `start()` clears the flag again.
    public func retry() async {
        await stop()
        await start()
    }

    /// Stop playback, report the final position, and tear down. Idempotent.
    public func stop() async {
        guard !hasStopped else { return }
        hasStopped = true

        let positionTicks = currentPositionTicks()

        progressTask?.cancel()
        progressTask = nil
        disarmSessionEvents()
        engine.teardown()
        delivery?.stop()
        delivery = nil
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil

        // The final playhead lands in the overlay immediately, so a shelf
        // behind the dismissing player shows the right resume bar on its
        // first frame (#193) — the server learns it via the report below.
        // Only when playback actually advanced: a session that never
        // rendered (delivery failure → Close, a retry's teardown) reads 0,
        // and recording that would wipe a real resume position.
        if positionTicks > 0 {
            userState.recordPosition(itemID: item.id, ticks: positionTicks)
        }

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

        // Belt to the stopped report's suspenders: release the transcode
        // explicitly (Swiftfin does the same on teardown)
        if playMethod != .directPlay, let playSessionId {
            await client.stopEncoding(playSessionId: playSessionId)
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
    /// This is the app-menu path, and post-#90 the app's menu carries only
    /// burn-in (image) tracks — AVKit's native picker owns text subtitles,
    /// selecting renditions directly on the player item, and the view model
    /// merely observes it (`reconcileMediaSelection`). Every change made
    /// here is a stream-shape change (a track burned in or out of the video
    /// by the server), so it always rebuilds.
    ///
    /// Critically, no path ever clears the legible selection in place
    /// anymore — and `PlayerEngine` deliberately offers no API to do so:
    /// AVKit latches its subtitle display off when it observes that clear,
    /// and the latch is process-global — it survives full recreation of the
    /// item, player, and player view controller (#91).
    public func selectSubtitleStream(index: Int?) async {
        guard index != selectedSubtitleStreamIndex else { return }
        selectedSubtitleStreamIndex = index
        await rebuildStream()
    }

    // MARK: - User-Data Actions

    /// Flip the playing item's favorite state through the user-state
    /// overlay — the same store the detail pages toggle, so a heart pressed
    /// mid-playback and one pressed on the detail page agree.
    public func toggleFavorite() async {
        let target = !isFavorite
        let token = userState.beginFavoriteToggle(itemID: item.id, target: target)
        do {
            if target {
                try await client.markFavorite(itemId: item.id)
            } else {
                try await client.unmarkFavorite(itemId: item.id)
            }
            userState.confirm(token)
        } catch {
            userState.revert(token)
            Self.logger.error("[favorite] \(target ? "mark" : "unmark", privacy: .public) FAILED \"\(self.item.name, privacy: .public)\": \(error, privacy: .public)")
        }
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

    /// The trickplay resolution for the current item's media source, when the
    /// server has seek-preview data (resolved during `start()`)
    private var trickplayInfo: TrickplayInfo?

    /// The current item's chapters (resolved during `start()`), empty when
    /// the server reports none
    private var chapters: [Chapter] = []

    /// The delivery serving the current stream to the engine; holds the
    /// loopback interposer on HLS sessions
    private var delivery: (any StreamDelivery)?

    /// In-flight artwork enrichment (chapter thumbnails + poster) for the
    /// current session
    private var metadataArtworkTask: Task<Void, Never>?

    private func beginPlayback(resolution: StreamResolution, resumeTicks: Int64) async {
        // The old session's delivery lives until its replacement is chosen,
        // exactly as the interposer did before the delivery seam existed
        delivery?.stop()
        delivery = nil

        let delivery = StreamDeliverySelector.delivery(
            for: resolution,
            context: DeliveryContext(
                itemId: item.id,
                mediaSource: mediaSource,
                playSessionId: playSessionId,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex,
                trickplayInfo: trickplayInfo,
                capabilities: engine.capabilities,
            ),
            client: client,
        )
        let delivered = await delivery.prepare()
        self.delivery = delivery
        // Delivery may correct the method (the degraded interposer fallback
        // does); the corrected value is what start reports must carry
        playMethod = delivered.playMethod

        sessionEpoch += 1
        engine.load(
            url: delivered.url,
            metadata: PlayerSessionMetadata(
                item: item,
                chapters: chapters,
                durationSeconds: itemDurationSeconds,
            ),
            // The legible group backs in-place text-rendition selection, so
            // it is skipped on direct play (no renditions; the embedded
            // defaults are left to the player). The audible group loads
            // everywhere — a direct-played file's embedded tracks are
            // exactly what the native audio picker switches behind the
            // app's back (#89).
            loadsLegibleOptions: playMethod != .directPlay,
        )
        startMetadataEnrichment()

        if resumeTicks > 0 {
            await engine.seekForResume(toSeconds: PlaybackTicks.seconds(fromTicks: resumeTicks))
        }

        engine.play()
        state = .playing

        // Arm the failure paths before anything that can await: until they
        // exist a delivery failure has no way to reach `state`, and the start
        // report below is a network round trip (#151)
        armDeliveryFailureDetection()

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
        steadyStateEventsArmed = true
    }

    private var itemDurationSeconds: Double? {
        item.runTimeTicks.map { PlaybackTicks.seconds(fromTicks: $0) }
    }

    /// Fetch chapter thumbnails and the poster off the critical path, then
    /// hand them to the engine in one re-application when they arrive.
    ///
    /// Text metadata lands synchronously inside `engine.load` — chapters
    /// are usable as soon as the transport bar appears — and thumbnails
    /// upgrade the markers when their fetches finish.
    private func startMetadataEnrichment() {
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil

        let posterURL = client.posterURL(for: item)
        guard !chapters.isEmpty || posterURL != nil else { return }

        let chapters = chapters
        let info = trickplayInfo
        let itemId = item.id
        let mediaSourceId = mediaSource?.id
        let client = client
        let epoch = sessionEpoch

        metadataArtworkTask = Task { [weak self] in
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

            // A rebuild or episode change may have swapped the session
            // mid-fetch; stale artwork must not reach the new stream
            guard !Task.isCancelled, let self, self.sessionEpoch == epoch else { return }
            self.engine.applyEnrichedMetadata(chapterArtwork: chapterArtwork, posterData: posterData)
        }
    }

    private func rebuildStream() async {
        guard engine.isLoaded else { return }

        let positionTicks = currentPositionTicks()

        // The old session gets no stopped report (the new one sends a fresh
        // start), so explicitly release its server-side transcode rather
        // than leaving an orphaned ffmpeg until the idle timeout
        if playMethod != .directPlay, let oldSession = playSessionId {
            await client.stopEncoding(playSessionId: oldSession)
        }

        progressTask?.cancel()
        disarmSessionEvents()
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil
        engine.teardown()

        state = .loading

        do {
            let session = try await client.getPlaybackInfo(
                itemId: item.id,
                startTimeTicks: positionTicks > 0 ? positionTicks : nil,
                audioStreamIndex: selectedAudioStreamIndex,
                subtitleStreamIndex: selectedSubtitleStreamIndex,
                capabilities: engine.capabilities,
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
                capabilities: engine.capabilities,
            )
            playMethod = resolution.playMethod
            sessionUsesBurnIn = source.subtitleRequiresBurnIn(at: selectedSubtitleStreamIndex)
            logResolution(resolution, source: source, context: "rebuild")

            await beginPlayback(resolution: resolution, resumeTicks: positionTicks)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reset every per-session event gate and cancel the watchdog. Runs on
    /// stop and rebuild, before the engine tears the session down.
    private func disarmSessionEvents() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        deliveryFailureEventsArmed = false
        steadyStateEventsArmed = false
        mediaSelectionReconcileArmed = false
    }

    // MARK: - Engine Events

    private func handleEngineEvent(_ event: PlayerEngineEvent) {
        // The gate is read once and then both logged and applied, so the
        // console line can never disagree with what actually happened.
        let isOpen = gateIsOpen(for: event)
        Self.logger.info("""
        [engine] \(Self.description(of: event), privacy: .public) \
        \(isOpen ? "handled" : "DROPPED (gate closed)", privacy: .public)
        """)
        guard isOpen else { return }

        switch event {
        case .transportStatusChanged:
            Task { @MainActor [weak self] in
                await self?.reportProgress()
            }

        case .playedToEnd:
            Task { @MainActor [weak self] in
                await self?.handlePlaybackEnded()
            }

        case .mediaSelectionChanged:
            Task { @MainActor [weak self] in
                await self?.reconcileMediaSelection()
            }

        case .mediaSelectionOptionsLoaded:
            mediaSelectionReconcileArmed = true

        case let .deliveryFailed(reason, cause):
            failDelivery(message: Self.deliveryFailureMessage(reason: reason), cause: cause)
        }
    }

    /// Whether this event class is open for business yet.
    ///
    /// Each gate reproduces the timing at which the pre-seam view model
    /// attached the corresponding observer, so no event acts earlier than it
    /// used to (#85). A closed gate drops the event outright — it is not
    /// queued — which is why `handleEngineEvent` logs the verdict.
    private func gateIsOpen(for event: PlayerEngineEvent) -> Bool {
        switch event {
        case .transportStatusChanged, .playedToEnd, .mediaSelectionChanged:
            steadyStateEventsArmed
        case .mediaSelectionOptionsLoaded:
            // Ungated: this only arms reconciliation, and it has to land
            // whenever the engine finishes loading its selection groups —
            // which on a fast stream can precede the start report.
            true
        case .deliveryFailed:
            deliveryFailureEventsArmed
        }
    }

    /// Console name for one engine event. The delivery-failure case carries
    /// the engine's own cause, so a device log names the signal that fired
    /// (item status vs. failed-to-play-to-end) rather than just the class.
    private static func description(of event: PlayerEngineEvent) -> String {
        switch event {
        case .transportStatusChanged: "transportStatusChanged"
        case .playedToEnd: "playedToEnd"
        case .mediaSelectionChanged: "mediaSelectionChanged"
        case .mediaSelectionOptionsLoaded: "mediaSelectionOptionsLoaded"
        case let .deliveryFailed(_, cause): "deliveryFailed(\(cause))"
        }
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
        guard mediaSelectionReconcileArmed, engine.isLoaded else { return }
        var changed = false

        if !engine.legibleOptions.isEmpty {
            let position = engine.selectedLegiblePosition
            let decision = Self.subtitleReconcileDecision(
                selectedPosition: position,
                currentIndex: selectedSubtitleStreamIndex,
                sessionUsesBurnIn: sessionUsesBurnIn,
                streams: mediaSource?.subtitleStreams ?? [],
                options: engine.legibleOptions,
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
        if engine.audibleOptions.count > 1 {
            let option = engine.selectedAudiblePosition
                .flatMap { position in engine.audibleOptions.first { $0.position == position } }
            let decision = Self.audioReconcileDecision(
                selectedOption: option,
                currentIndex: selectedAudioStreamIndex,
                streams: mediaSource?.audioStreams ?? [],
                options: engine.audibleOptions,
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
    /// index. Pure so the matrix is unit-testable without a player.
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
    /// index. Pure so the matrix is unit-testable without a player.
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

    // MARK: - Delivery Failures

    /// How long the app waits for evidence of delivery before it looks again.
    ///
    /// This deadline is the app's only defence against an indefinite hang
    /// (#151): AVFoundation has no "the video never arrived" callback, so a
    /// stream that simply never produces bytes leaves the player sitting
    /// there forever.
    ///
    /// It is an *interval*, not a budget. The watchdog re-arms it for as long
    /// as the buffer keeps growing, so a slow start is bounded by how long the
    /// media takes to arrive rather than by this number. What the value sets
    /// is how coarsely delivery is sampled: how long a genuinely dead stream
    /// sits before the viewer is told, and how long a link slow enough to move
    /// less than a rounding error in one interval has to prove itself.
    ///
    /// **30s was chosen by reasoning, not measured.** Cold transcode starts
    /// are commonly in the 10–20s range. Nothing in this repo can measure it —
    /// playback behaviour is invisible to every test suite here (see
    /// CLAUDE.md) — so if it ever needs revisiting, bisect it against a real
    /// Apple TV and the local Jellyfin server. Note the failure mode that
    /// motivated the re-arming loop: at a fixed 30s, a file that direct-played
    /// fine on a healthy network raised an error screen under tvOS's network
    /// conditioner, because the playhead was the only progress signal and it
    /// does not move while the buffer fills.
    static let firstFrameTimeout: Duration = .seconds(30)

    /// What an elapsed first-frame deadline means for the current session
    enum FirstFrameVerdict: Equatable {
        /// Frames are flowing, or the viewer paused before they could arrive.
        /// Neither is a delivery failure, so the session is left alone and the
        /// deadline retires.
        case noFailure
        /// Nothing has played yet, but media is still arriving — a link too
        /// narrow for the stream, not a server that stopped answering. Give it
        /// another deadline rather than an error screen.
        case keepWaiting
        /// Nothing arrived and nothing is on its way; show this message.
        case failed(String)
    }

    /// Decide whether an elapsed first-frame deadline is a delivery failure.
    ///
    /// Pure so the matrix is unit-testable without an engine — no suite in
    /// this repo can drive a real one.
    ///
    /// - Parameters:
    ///   - transportStatus: the engine's transport state at the deadline
    ///   - positionAdvanced: whether the playhead moved past where the
    ///     watchdog was armed (i.e. after any resume seek had landed)
    ///   - errorDescription: the engine's error, non-nil only once playback
    ///     has failed outright
    ///   - progress: buffered duration and bytes transferred, sampled now
    ///   - previousProgress: the same pair at the previous deadline, zero on
    ///     the first
    static func firstFrameVerdict(
        transportStatus: PlaybackTransportStatus,
        positionAdvanced: Bool,
        errorDescription: String?,
        progress: DeliveryProgress,
        previousProgress: DeliveryProgress,
    ) -> FirstFrameVerdict {
        // An error is only published once playback has failed outright, and
        // no amount of further waiting recovers from that. Checked first
        // because a failed item drops the rate to zero, which would otherwise
        // look identical to the viewer having paused.
        if let errorDescription {
            return .failed(deliveryFailureMessage(reason: errorDescription))
        }
        // The playhead moving is the closest thing to a rendered-frame signal
        // AVFoundation offers without a render callback
        if positionAdvanced {
            return .noFailure
        }

        switch transportStatus {
        case .playing:
            // Frames are flowing; the clock just has not crossed a whole tick
            return .noFailure
        case .paused:
            // The viewer stopped waiting themselves. Failing here would
            // replace a deliberate pause with an error screen, so a session
            // paused before its first frame is left alone — a genuine failure
            // on resume still reaches the app via the engine's failure
            // events.
            return .noFailure
        case .waitingToPlay:
            // A rate was requested and nothing has played. Whether that is a
            // failure depends on whether media is still arriving.
            //
            // Advancing progress means the link is merely too narrow for the
            // stream — a conditioned link, a distant server, a bitrate the
            // connection cannot carry. That is slow, not broken, and it
            // produced this classifier's first false positives: a file that
            // direct-played fine on a healthy network raised an error screen
            // under a throttled one, because the playhead was the only
            // progress signal and it does not move while media buffers.
            //
            // Progress that has not moved since the last deadline is the
            // failure this whole mechanism exists for: a rate was requested,
            // the deadline is up, and nothing at all is arriving.
            return progress.advanced(since: previousProgress)
                ? .keepWaiting
                : .failed(firstFrameTimeoutMessage)
        }
    }

    /// Message for a failure the engine reported, with its own reason
    /// appended when it has one. Deliberately says what the viewer can do,
    /// because the only control on the error screen is Close.
    static func deliveryFailureMessage(reason: String?) -> String {
        let advice = """
        The server stopped delivering this video. It may have run out of \
        resources, or the connection may have dropped. Try playing it again.
        """
        guard let reason, !reason.isEmpty else { return advice }
        return "\(advice)\n\n\(reason)"
    }

    /// Message for a deadline that elapsed with nothing delivered at all.
    ///
    /// Names no duration on purpose: the deadline extends itself while the
    /// buffer grows, so by the time this is shown the wait may have been far
    /// longer than `firstFrameTimeout` and any figure here would be a lie.
    static var firstFrameTimeoutMessage: String {
        """
        Playback never started. The server may not be delivering this file, \
        or the connection may be too slow to carry it.
        """
    }

    /// Arm delivery-failure detection for the session that just called
    /// `play()`: open the gate for the engine's `.deliveryFailed` events,
    /// surface any failure that happened before the gate opened, and start
    /// the first-frame deadline.
    private func armDeliveryFailureDetection() {
        deliveryFailureEventsArmed = true
        // The engine's `.initial` status check may have fired into a closed
        // gate (its event hops the main actor, so it can land during the
        // resume seek); reading the error here restores the original
        // attach-time check
        if let reason = engine.currentErrorDescription {
            failDelivery(
                message: Self.deliveryFailureMessage(reason: reason),
                cause: "player item status failed",
            )
        }
        startFirstFrameWatchdog()
    }

    /// Arm the first-frame deadline for the session that just called `play()`.
    ///
    /// The baseline is the position *after* any resume seek, not the
    /// requested resume tick: seeking with a forward tolerance can land well
    /// past what was asked for, and comparing against the request would read
    /// that jump as playback progress.
    private func startFirstFrameWatchdog() {
        firstFrameWatchdog?.cancel()
        let baseline = currentPositionTicks()
        firstFrameWatchdog = Task { [weak self] in
            // A loop, not a single deadline: as long as media keeps arriving
            // the session earns another one. Delivery is not a failure however
            // slow it is, and the loop ends itself the moment it stops — so a
            // narrow link waits, while a silent server still fails on
            // schedule.
            var previous = DeliveryProgress()
            while true {
                try? await Task.sleep(for: Self.firstFrameTimeout)
                guard !Task.isCancelled, let self else { return }
                let progress = self.engine.deliveryProgress()
                guard self.firstFrameDeadlineElapsed(
                    baseline: baseline,
                    progress: progress,
                    previousProgress: previous,
                ) else { return }
                previous = progress
            }
        }
    }

    /// Apply the verdict for one elapsed deadline. Returns whether the
    /// watchdog should arm another.
    private func firstFrameDeadlineElapsed(
        baseline: Int64,
        progress: DeliveryProgress,
        previousProgress: DeliveryProgress,
    ) -> Bool {
        guard engine.isLoaded, !hasStopped else { return false }

        // Both measures on every deadline, including the failing one. Which of
        // them moved is the whole diagnosis when this misfires — a run that
        // fails with bytes climbing means something other than delivery is
        // wrong, and a run that fails with both flat is the real thing.
        // `String(format:)`, not os_log's `format: .fixed(precision:)`: that
        // spelling is `OSLogMessage` interpolation and does not exist on
        // `String`. Xcode 27 beta compiled it anyway; release Xcode and CI do
        // not.
        let sample = String(
            format: "buffered=%.1fs bytes=%lld (was %.1fs / %lld)",
            progress.bufferedSeconds,
            progress.bytesTransferred,
            previousProgress.bufferedSeconds,
            previousProgress.bytesTransferred,
        )

        switch Self.firstFrameVerdict(
            transportStatus: engine.transportStatus,
            positionAdvanced: currentPositionTicks() > baseline,
            errorDescription: engine.currentErrorDescription,
            progress: progress,
            previousProgress: previousProgress,
        ) {
        case .noFailure:
            Self.logger.debug("[delivery] deadline passed with playback under way — \(sample, privacy: .public)")
            return false
        case .keepWaiting:
            Self.logger.debug("[delivery] deadline extended, media still arriving — \(sample, privacy: .public)")
            return true
        case let .failed(message):
            Self.logger.error("[delivery] deadline elapsed with nothing arriving — \(sample, privacy: .public)")
            failDelivery(message: message, cause: "first-frame timeout")
            return false
        }
    }

    /// Move a live session to `.failed`.
    ///
    /// Guarded on state and stop so a late signal — from a session that
    /// already ended — cannot throw an error screen over a healthy player;
    /// stale engine callbacks from a replaced stream never get this far
    /// (the engine drops them by generation).
    ///
    /// The engine is paused rather than torn down here. Full teardown (the
    /// stopped report and `stopEncoding`) belongs to `stop()`, which
    /// `PlaybackContainerView.onDisappear` always runs when the viewer
    /// presses Close — the only exit from the error screen. Keeping the
    /// session addressable until then also keeps it diagnosable.
    private func failDelivery(message: String, cause: String) {
        guard !hasStopped, engine.isLoaded else { return }
        switch state {
        case .playing, .loading: break
        case .idle, .failed, .finished: return
        }

        Self.logger.error("""
        [delivery] FAILED (\(cause, privacy: .public)) \
        "\(self.item.name, privacy: .public)" \
        method=\(String(describing: self.playMethod), privacy: .public)
        """)

        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        engine.pause()
        state = .failed(message)
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
        guard engine.isLoaded, !hasStopped else { return }

        let positionTicks = currentPositionTicks()
        // Tracked locally regardless of whether the report lands — the
        // viewer's position is a fact about the viewer, not the network
        userState.recordPosition(itemID: item.id, ticks: positionTicks)
        do {
            try await client.reportPlaybackProgress(
                itemId: item.id,
                mediaSourceId: mediaSource?.id,
                playSessionId: playSessionId,
                positionTicks: positionTicks,
                playMethod: playMethod,
                isPaused: engine.transportStatus == .paused,
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
        guard let seconds = engine.currentTimeSeconds,
              seconds.isFinite, seconds > 0 else { return 0 }
        return PlaybackTicks.ticks(fromSeconds: seconds)
    }
}

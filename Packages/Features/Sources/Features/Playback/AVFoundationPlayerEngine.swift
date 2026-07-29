import AVFoundation
import Foundation
import JellyfinKit
import Observation
import OSLog

/// The AVFoundation implementation of `PlayerEngine`: owns the `AVPlayer`,
/// its KVO and notification observers, media-selection group loading, and
/// AVKit-facing metadata. Everything AVFoundation in playback lives here or
/// in the view layer that hosts the player — never in `PlaybackViewModel`.
///
/// `@Observable` is load-bearing: `PlaybackContainerView` reads `player` in
/// its body to feed `AVPlayerViewController`, and a mid-session rebuild
/// (track switch) swaps the player instance. Without observation the view
/// would keep rendering the dead player.
@Observable
@MainActor
final class AVFoundationPlayerEngine: PlayerEngine {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    /// The player, for the hosting view. Not part of `PlayerEngine`: only
    /// the AVKit hosting path needs it, and it holds a typed reference to
    /// this engine.
    private(set) var player: AVPlayer?

    @ObservationIgnored var onEvent: ((PlayerEngineEvent) -> Void)?

    /// Stale-callback fence. Every async completion and observer callback
    /// captures the generation of the `load` that armed it and is dropped
    /// when a newer `load`/`teardown` has moved the session on — one owner
    /// for the guards the view model used to spell as
    /// `player?.currentItem === playerItem` (#85).
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failedToEndObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaSelectionObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaSelectionTask: Task<Void, Never>?

    /// The current item's audible/legible media-selection groups, kept
    /// solely so selection positions can be read back for reconciliation.
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?

    private(set) var audibleOptions: [AudibleOption] = []
    private(set) var legibleOptions: [LegibleOption] = []

    /// What `load` was asked to present, kept for enrichment re-application
    @ObservationIgnored private var sessionMetadata: PlayerSessionMetadata?

    // MARK: - Lifecycle

    func load(url: URL, metadata: PlayerSessionMetadata, loadsLegibleOptions: Bool) {
        removeObservers()
        generation += 1
        let generation = generation

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        // The master playlist marks every text rendition AUTOSELECT=YES;
        // left on, AVPlayer would enable subtitles from system accessibility
        // preferences behind the app's explicit selection state
        player.appliesMediaSelectionCriteriaAutomatically = false
        self.player = player
        sessionMetadata = metadata

        applyMetadata(metadata, to: playerItem)

        // Failure observers first — the #151 obligation this method's
        // contract states. The rest are armed here too; the session layer
        // decides when each event class starts mattering.
        observeItemStatus(of: playerItem, generation: generation)
        observeFailedToPlayToEnd(of: playerItem, generation: generation)
        observeTimeControlStatus(of: player, generation: generation)
        observeEnd(of: playerItem, generation: generation)
        observeMediaSelection(of: playerItem, generation: generation)
        loadMediaSelectionOptions(for: playerItem, loadsLegible: loadsLegibleOptions, generation: generation)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seekForResume(toSeconds seconds: Double) async {
        guard let player else { return }
        await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .positiveInfinity,
        )
    }

    func teardown() {
        removeObservers()
        generation += 1
        sessionMetadata = nil
        player?.pause()
        player = nil
    }

    private func removeObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        failedToEndObserver = nil
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
        }
        mediaSelectionObserver = nil
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        audibleGroup = nil
        audibleOptions = []
        legibleGroup = nil
        legibleOptions = []
    }

    // MARK: - State

    var isLoaded: Bool {
        player != nil
    }

    var currentTimeSeconds: Double? {
        player?.currentTime().seconds
    }

    var transportStatus: PlaybackTransportStatus {
        switch player?.timeControlStatus {
        case .playing: .playing
        case .waitingToPlayAtSpecifiedRate: .waitingToPlay
        case .paused, .none: .paused
        @unknown default: .paused
        }
    }

    var currentErrorDescription: String? {
        guard let player else { return nil }
        return (player.currentItem?.error ?? player.error)?.localizedDescription
    }

    func deliveryProgress() -> DeliveryProgress {
        guard let item = player?.currentItem else { return DeliveryProgress() }
        return DeliveryProgress(
            bufferedSeconds: item.loadedTimeRanges
                .reduce(0) { $0 + CMTimeGetSeconds($1.timeRangeValue.duration) },
            // Summed, not last-event: the access log accumulates an event per
            // delivery segment, so the tail alone can go down between samples
            // while the total is still climbing.
            bytesTransferred: item.accessLog()?.events
                .reduce(0) { $0 + $1.numberOfBytesTransferred } ?? 0,
        )
    }

    // MARK: - Media Selection

    var selectedAudiblePosition: Int? {
        guard let item = player?.currentItem, let group = audibleGroup else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)
            .flatMap { group.options.firstIndex(of: $0) }
    }

    var selectedLegiblePosition: Int? {
        guard let item = player?.currentItem, let group = legibleGroup else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group)
            .flatMap { group.options.firstIndex(of: $0) }
    }

    /// Load the media-selection groups of the freshly created player item,
    /// then announce readiness so the session layer can arm reconciliation.
    private func loadMediaSelectionOptions(
        for playerItem: AVPlayerItem,
        loadsLegible: Bool,
        generation: Int,
    ) {
        mediaSelectionTask = Task { [weak self] in
            await self?.loadAudibleGroup(for: playerItem, generation: generation)
            if loadsLegible {
                await self?.loadLegibleGroup(for: playerItem, generation: generation)
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.onEvent?(.mediaSelectionOptionsLoaded)
        }
    }

    private func loadAudibleGroup(for playerItem: AVPlayerItem, generation: Int) async {
        do {
            guard let group = try await playerItem.asset.loadMediaSelectionGroup(for: .audible) else {
                Self.logger.debug("[audio] stream carries no audible group")
                return
            }
            guard !Task.isCancelled, self.generation == generation else { return }
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

    private func loadLegibleGroup(for playerItem: AVPlayerItem, generation: Int) async {
        do {
            guard let group = try await playerItem.asset.loadMediaSelectionGroup(for: .legible) else {
                // Normal on a stream with no legible renditions
                Self.logger.debug("[subtitle] stream carries no legible group")
                return
            }
            guard !Task.isCancelled, self.generation == generation else { return }
            legibleGroup = group
            legibleOptions = group.options.enumerated().map { position, option in
                LegibleOption(
                    position: position,
                    displayName: option.displayName,
                    languageTag: option.extendedLanguageTag,
                )
            }
            Self.logger.debug("[subtitle] legible options loaded: \(self.legibleOptions.count)")
            // Deliberately no selection is applied. AVKit owns text
            // subtitles: its picker, the rendition's DEFAULT/AUTOSELECT
            // flags, and the viewer's system caption preference decide what
            // renders. The app used to select and clear here — and the clear
            // (`select(nil)`) latched AVKit's subtitle display off
            // process-wide, surviving full player recreation (#91). The
            // group and options are kept solely so selection positions can
            // be read back for reconciliation.
        } catch {
            // The root of the subtitle pipeline: if this load fails, no
            // rendition can ever be selected and every diagnostic
            // downstream is unreachable, so record the cause at a
            // persisted level
            Self.logger.warning("[subtitle] legible group load failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Metadata

    private func applyMetadata(_ metadata: PlayerSessionMetadata, to playerItem: AVPlayerItem) {
        playerItem.externalMetadata = PlayerMetadataFactory.externalMetadata(for: metadata.item)

        #if os(tvOS)
            if let duration = metadata.durationSeconds,
               let group = PlayerMetadataFactory.navigationMarkerGroup(
                   chapters: metadata.chapters,
                   durationSeconds: duration,
               )
            {
                playerItem.navigationMarkerGroups = [group]
            }
        #endif
    }

    func applyEnrichedMetadata(chapterArtwork: [Int: Data], posterData: Data?) {
        guard let playerItem = player?.currentItem, let metadata = sessionMetadata else { return }
        guard !chapterArtwork.isEmpty || posterData != nil else { return }

        playerItem.externalMetadata = PlayerMetadataFactory.externalMetadata(
            for: metadata.item,
            artworkData: posterData,
        )

        #if os(tvOS)
            if !chapterArtwork.isEmpty,
               let duration = metadata.durationSeconds,
               let group = PlayerMetadataFactory.navigationMarkerGroup(
                   chapters: metadata.chapters,
                   durationSeconds: duration,
                   artwork: chapterArtwork,
               )
            {
                playerItem.navigationMarkerGroups = [group]
            }
        #endif
    }

    // MARK: - Observers

    private func observeTimeControlStatus(of player: AVPlayer, generation: Int) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onEvent?(.transportStatusChanged)
            }
        }
    }

    /// Watch the item's `status` for an outright failure.
    ///
    /// This is the one signal that distinguishes a real failure from the
    /// benign asset/track noise AVFoundation logs during ordinary HLS setup
    /// ("Asset has no tracks", FSTL errors — see the AVPlayer notes in
    /// CLAUDE.md's history). Those never drive `status` to `.failed`, and
    /// the error log is deliberately not consulted for exactly that reason.
    /// `.initial` covers an item that had already failed by the time this
    /// registration ran.
    private func observeItemStatus(of playerItem: AVPlayerItem, generation: Int) {
        itemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onEvent?(.deliveryFailed(reason: reason, cause: "player item status failed"))
            }
        }
    }

    /// Watch for AVFoundation giving up on a stream that had been playing.
    ///
    /// Its sibling `playbackStalledNotification` is deliberately NOT
    /// observed: a stall is a rebuffer, it recovers on its own, and treating
    /// one as fatal would turn every slow moment on a busy network into an
    /// error screen.
    private func observeFailedToPlayToEnd(of playerItem: AVPlayerItem, generation: Int) {
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem,
            queue: .main,
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)?
                .localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onEvent?(.deliveryFailed(reason: reason, cause: "failed to play to end"))
            }
        }
    }

    private func observeEnd(of playerItem: AVPlayerItem, generation: Int) {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onEvent?(.playedToEnd)
            }
        }
    }

    private func observeMediaSelection(of playerItem: AVPlayerItem, generation: Int) {
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: playerItem,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onEvent?(.mediaSelectionChanged)
            }
        }
    }
}

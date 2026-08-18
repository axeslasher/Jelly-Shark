import AVFoundation
import Foundation
import JellyfinKit
import Observation
import OSLog
#if os(tvOS)
    import AVKit
    import UIKit
#endif

/// The AVFoundation implementation of `PlayerEngine`: owns the `AVPlayer`,
/// its KVO and notification observers, media-selection group loading, and
/// AVKit-facing metadata. Everything AVFoundation in playback lives here or
/// in the view layer that hosts the player — never in `PlaybackViewModel`.
///
/// `@Observable` is load-bearing: `PlaybackContainerView` reads `player` in
/// its body to feed `AVPlayerViewController`, and the first load has to reach
/// the view. A mid-session rebuild deliberately does *not* change the
/// instance — it replaces the item underneath (see `load`) — so within a
/// session the view sees one player from first frame to teardown.
@Observable
@MainActor
final class AVFoundationPlayerEngine: PlayerEngine {
    // `nonisolated`: `Logger` is Sendable, and the dropped-frame sampler logs
    // from its own queue.
    private nonisolated static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")

    /// What AVFoundation on tvOS/visionOS decodes and displays. These are
    /// facts about AVPlayer and the Apple hardware behind it — not about
    /// Jellyfin, and not about the app — which is why the engine owns them
    /// and JellyfinKit derives the wire-format DeviceProfile (#85).
    /// (`nonisolated`: immutable Sendable state, readable off the actor.)
    ///
    /// **Amending this means amending `PlaybackCapabilitiesFixture` in
    /// JellyfinKitTests too.** That fixture is a hand-copy of these values
    /// — the host suite cannot import Features — and nothing asserts the
    /// two are equal, because they live in test targets that cannot see
    /// each other. `PlaybackCapabilitiesDeclarationTests` will fail here
    /// and point at the change; nothing will point at the fixture, and a
    /// stale one leaves `DeviceProfileTests` proving a derivation no
    /// engine actually sends.
    nonisolated static let capabilities = PlaybackCapabilities(
        name: "Jelly Shark",
        // 120 Mbps comfortably covers 4K remuxes on a LAN while still
        // letting the server transcode down for genuinely enormous sources
        maxStreamingBitrate: 120_000_000,
        directPlay: [
            PlaybackCapabilities.DirectPlayRule(
                containers: ["mp4", "m4v", "mov"],
                videoCodecs: ["hevc", "h264"],
                audioCodecs: ["aac", "ac3", "eac3", "flac", "alac"],
            ),
        ],
        // Conditions a source's video stream must meet for the blanket
        // direct-play claims to hold. Without these the server offers
        // direct play for variants AVFoundation can't decode. Mirrors
        // Swiftfin's AVKit conditions.
        videoCodecRules: [
            // AVFoundation only decodes HEVC in mp4/m4v/mov when the
            // sample entry is tagged hvc1 (or Dolby Vision's dvh1).
            // ffmpeg tags hev1 by default, which plays audio over a
            // black screen — route those through HLS instead.
            //
            // Scoped to the mp4 family: only those containers carry a
            // sample-entry tag at all. MKV video streams have none
            // (CodecTag=null), so an unscoped required condition failed
            // every HEVC MKV and forced a pointless re-encode the server's
            // own remux would have made moot — it retags to hvc1 when
            // copying into fMP4 segments (#146).
            PlaybackCapabilities.VideoCodecRule(
                codec: "hevc",
                containers: ["mp4", "m4v", "mov"],
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoCodecTag,
                        comparison: .equalsAny,
                        value: "hvc1|dvh1",
                        isRequired: true,
                    ),
                ],
            ),
            // Declare the video ranges the device can display, so the
            // server stream-copies HDR instead of tone-mapping it to
            // SDR: an undeclared client is assumed SDR-only, and the
            // tone-map means a full-resolution software re-encode that
            // runs far below realtime and starves playback (#146).
            //
            // Dolby Vision profile 7 (DOVIWithEL) is absent because no
            // Apple hardware decodes the dual layer.
            //
            // This used to claim the omission *selects* the server's
            // strip-to-HDR10 copy path (10.11+). Measured 2026-07-28
            // against Jellyfin 10.11.11, that is false: a DV profile 7.6
            // source (VideoRangeType 8), matching nothing declared here,
            // was tone-mapped to BT.709 by a libx264 software encode and
            // downscaled to 1080p. On a CPU-only server that ran at ~0.4x
            // realtime — the first frame rendered and the playhead never
            // moved. Whether declaring DOVIWithEL instead yields a
            // playable strip-and-copy is an open device experiment (#172).
            //
            // Profile 5 (DOVI) is absent until DV playlist signaling is
            // verified on device: it has no HDR10 base layer, so an
            // unsignaled copy displays with broken color.
            //
            // isRequired stays false so sources with an unprobed range
            // aren't needlessly rejected. This condition is the single
            // stored source for the range set — the stream URL's
            // `hevc-rangetype` option reads it back comma-separated.
            PlaybackCapabilities.VideoCodecRule(
                codec: "hevc",
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoRangeType,
                        comparison: .equalsAny,
                        value: "SDR|HDR10|HLG|DOVIWithHDR10",
                        isRequired: false,
                    ),
                ],
            ),
            // No Apple hardware decodes 10-bit H.264 (Hi10P), and only
            // the mainstream profiles are supported. isRequired stays
            // false so sources with unprobed depth/profile aren't
            // needlessly rejected.
            PlaybackCapabilities.VideoCodecRule(
                codec: "h264",
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoBitDepth,
                        comparison: .lessThanEqual,
                        value: "8",
                        isRequired: false,
                    ),
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoProfile,
                        comparison: .equalsAny,
                        value: "high|main|baseline|constrained baseline",
                        isRequired: false,
                    ),
                ],
            ),
        ],
        subtitles: [
            // AVPlayer renders embedded tx3g (mov_text) natively; without
            // this declaration the server refuses to direct play any
            // mp4/mov that merely CONTAINS such a track
            PlaybackCapabilities.SubtitleRule(format: "mov_text", delivery: .embed),
            // External keeps SupportsDirectPlay=true for files that have
            // text sidecars: without it the server reports
            // SubtitleCodecNotSupported and forces a transcode even when
            // no subtitle was requested. Selected text subs are still
            // delivered as HLS renditions via SubtitleMethod on the
            // stream URL.
            PlaybackCapabilities.SubtitleRule(format: "vtt", delivery: .external),
            PlaybackCapabilities.SubtitleRule(format: "subrip", delivery: .external),
            PlaybackCapabilities.SubtitleRule(format: "vtt", delivery: .hls),
            PlaybackCapabilities.SubtitleRule(format: "subrip", delivery: .hls),
            PlaybackCapabilities.SubtitleRule(format: "ass", delivery: .encode),
            PlaybackCapabilities.SubtitleRule(format: "ssa", delivery: .encode),
            PlaybackCapabilities.SubtitleRule(format: "pgssub", delivery: .encode),
            PlaybackCapabilities.SubtitleRule(format: "dvdsub", delivery: .encode),
        ],
        // Advertise both segment containers StreamURLBuilder may request:
        // fMP4 (the default, and the only one Apple decodes HEVC from) and
        // ts (used only when a text subtitle rides along) — see the
        // SegmentContainer comment there.
        transcoding: PlaybackCapabilities.TranscodingRule(
            containers: ["mp4", "ts"],
            videoCodecs: ["hevc", "h264"],
            audioCodecs: ["aac", "ac3", "eac3"],
            minSegments: 2,
            breaksOnNonKeyFrames: true,
        ),
    )

    nonisolated var capabilities: PlaybackCapabilities {
        Self.capabilities
    }

    /// The player, for the hosting view. Not part of `PlayerEngine`: only
    /// the AVKit hosting path needs it, and it holds a typed reference to
    /// this engine.
    private(set) var player: AVPlayer?

    @ObservationIgnored var onEvent: ((PlayerEngineEvent) -> Void)?

    /// Stale-callback fence. Every async completion and observer callback
    /// captures the generation of the `load` that armed it and is dropped
    /// when a newer `load`, a `teardown`, or a `suspendForRebuild` has moved
    /// the session on — one owner
    /// for the guards the view model used to spell as
    /// `player?.currentItem === playerItem` (#85).
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?

    /// Last transport status handed to the session layer, so the observation
    /// can tell a real transition from a repeat notification without reading
    /// the change dictionary. See `observeTimeControlStatus`.
    @ObservationIgnored private var lastTransportStatus: AVPlayer.TimeControlStatus?

    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failedToEndObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaSelectionObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaSelectionTask: Task<Void, Never>?
    /// Playback-health sampling for the current session — see
    /// `observePlaybackHealth` for why this is periodic and off-main rather
    /// than notification-driven. The token must be removed from the same
    /// player it was added to; the engine only ever has one player, so the
    /// stored `player` is that player.
    @ObservationIgnored private var healthSampler: PlaybackHealthSampler?
    @ObservationIgnored private var healthTimeObserver: Any?

    #if os(tvOS)
        /// The Up Next proposal waiting to attach, kept so a duration that
        /// arrives after `setUpNextProposal` was called (common on
        /// HLS/transcode, where the item's duration resolves only once the
        /// playlists parse) can still attach it instead of the proposal being
        /// dropped for the whole session (#186).
        @ObservationIgnored private var pendingUpNextProposal: UpNextProposal?

        /// Fires once the current item's duration becomes known, to attach a
        /// proposal that couldn't be built at request time. Invalidated as
        /// soon as it succeeds, on a new request, and in `removeObservers`.
        @ObservationIgnored private var upNextDurationObservation: NSKeyValueObservation?
    #endif

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

        // Replace the *item*, not the player, when a session is already up.
        //
        // A rebuild keeps `AVPlayerViewController` mounted (#183), and handing
        // a mounted controller a different `AVPlayer` is not a shape AVKit
        // supports on visionOS: its RealityKit video entity loses its player
        // component ("no videoPlayerComponent on <VideoEntity:…>", followed by
        // a burst of SwiftUI runtime faults from AVKit's own internals).
        // Apple's own guidance for changing what a mounted player shows is
        // `replaceCurrentItem` — swapping the controller's player is only for
        // a controller SwiftUI is about to rebuild anyway.
        let player: AVPlayer
        if let existing = self.player {
            existing.replaceCurrentItem(with: playerItem)
            player = existing
        } else {
            player = AVPlayer(playerItem: playerItem)
            // The master playlist marks every text rendition AUTOSELECT=YES;
            // left on, AVPlayer would enable subtitles from system
            // accessibility preferences behind the app's explicit selection
            // state. A player property, so it survives item replacement.
            player.appliesMediaSelectionCriteriaAutomatically = false
            self.player = player
        }
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
        observePlaybackHealth(of: player)
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

    func suspendForRebuild() {
        removeObservers()
        generation += 1
        player?.pause()
    }

    private func removeObservers() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        lastTransportStatus = nil
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
        if let healthTimeObserver {
            player?.removeTimeObserver(healthTimeObserver)
        }
        healthTimeObserver = nil
        // Playback of this item is over (teardown, rebuild, or a new load):
        // one last read catches drops after the final periodic tick.
        healthSampler?.stopTimelineWatch()
        if let sampler = healthSampler, let item = player?.currentItem {
            sampler.flush(item)
        }
        healthSampler = nil
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        audibleGroup = nil
        audibleOptions = []
        legibleGroup = nil
        legibleOptions = []
        #if os(tvOS)
            upNextDurationObservation?.invalidate()
            upNextDurationObservation = nil
            pendingUpNextProposal = nil
        #endif
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

    func selectAudible(position: Int) {
        guard let item = player?.currentItem, let group = audibleGroup else {
            Self.logger.warning("[audio] selectAudible(\(position)) with no loaded audible group")
            return
        }
        guard group.options.indices.contains(position) else {
            Self.logger.warning("[audio] selectAudible(\(position)) out of range (\(group.options.count) options)")
            return
        }
        item.select(group.options[position], in: group)
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
            Self.logger.warning("[audio] audible group load failed: \(PlaybackLog.error(error), privacy: .public)")
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
            Self.logger.warning("[subtitle] legible group load failed: \(PlaybackLog.error(error), privacy: .public)")
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

    func setUpNextProposal(_ proposal: UpNextProposal?) {
        #if os(tvOS)
            // Any earlier wait-for-duration is superseded by this request.
            upNextDurationObservation?.invalidate()
            upNextDurationObservation = nil
            pendingUpNextProposal = proposal

            guard let playerItem = player?.currentItem else {
                Self.logger.info("[upnext] setProposal(\(proposal == nil ? "nil" : "value")) with no current item")
                return
            }

            guard let proposal else {
                playerItem.nextContentProposal = nil
                Self.logger.info("[upnext] proposal cleared")
                return
            }

            // Attach now if the item's duration is already known; otherwise
            // wait for it rather than dropping the proposal for good.
            switch attachUpNextProposal(proposal, to: playerItem) {
            case .attached, .unsuitable:
                break
            case .durationNotReady:
                Self.logger.info("[upnext] duration not ready (\(playerItem.duration.seconds, format: .fixed(precision: 1))s); waiting to attach")
                let gen = generation
                upNextDurationObservation = playerItem.observe(\.duration, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen, self.player?.currentItem === item,
                              let pending = self.pendingUpNextProposal else { return }
                        if self.attachUpNextProposal(pending, to: item) != .durationNotReady {
                            self.upNextDurationObservation?.invalidate()
                            self.upNextDurationObservation = nil
                        }
                    }
                }
            }
        #endif
    }

    #if os(tvOS)
        private enum UpNextAttachOutcome {
            /// Attached — AVKit will present the card at the transition time.
            case attached
            /// Duration is known but shorter than the lead window: correctly
            /// presents nothing, and there is nothing to wait for.
            case unsuitable
            /// Duration is not numeric yet (unloaded, or a live/indefinite
            /// stream): the caller waits for it to become known.
            case durationNotReady
        }

        /// Build and attach the `AVContentProposal` if the item's duration is
        /// known, against the *concrete* player-item timeline (#186) rather
        /// than the Jellyfin runtime, so the transition lands at a real time.
        private func attachUpNextProposal(_ proposal: UpNextProposal, to playerItem: AVPlayerItem) -> UpNextAttachOutcome {
            let duration = playerItem.duration
            let endSeconds = duration.seconds
            guard duration.isNumeric, endSeconds.isFinite else {
                return .durationNotReady
            }
            guard endSeconds > proposal.leadSeconds else {
                playerItem.nextContentProposal = nil
                Self.logger.info("[upnext] item too short (\(endSeconds, format: .fixed(precision: 1))s ≤ lead \(proposal.leadSeconds, format: .fixed(precision: 1))s); no proposal")
                return .unsuitable
            }

            let transitionSeconds = endSeconds - proposal.leadSeconds
            let content = UpNextContentProposal(
                contentTimeForTransition: CMTime(seconds: transitionSeconds, preferredTimescale: 600),
                title: proposal.title,
                previewImage: proposal.previewImageData.flatMap(UIImage.init(data:)),
                episodeCode: proposal.episodeCode,
            )
            // AVKit drives the countdown-to-autoplay itself, replacing the
            // app's hand-rolled `Task` timer. Per `AVContentProposal.h` and
            // Apple's tvOS sample the interval is measured from the item's
            // *end* and negative (NAN, the default, disables auto-accept), so a
            // small negative value auto-accepts a beat before the natural
            // ending, leaving it briefly on screen.
            content.automaticAcceptanceInterval = -proposal.autoAcceptSeconds
            playerItem.nextContentProposal = content
            Self.logger.info("[upnext] attached \"\(proposal.title, privacy: .public)\": end=\(endSeconds, format: .fixed(precision: 1))s transition=\(transitionSeconds, format: .fixed(precision: 1))s image=\(proposal.previewImageData != nil)")
            return .attached
        }
    #endif

    // MARK: - Observers

    /// Emit `.transportStatusChanged` on every real play/pause transition.
    ///
    /// The status is read live off the player rather than out of the change
    /// dictionary. Typed KVO decodes `change.oldValue`/`newValue` by bridging
    /// an `NSNumber` into `AVPlayer.TimeControlStatus`, an imported
    /// Objective-C enum, and that bridge yields nil for both — so the
    /// `oldValue != newValue` guard this used to open with evaluated
    /// `nil != nil` and returned on *every* fire. The event never reached the
    /// session layer, and pause/resume waited up to a full progress interval
    /// to reach the server instead of reporting promptly (#181).
    ///
    /// Dedupe therefore happens here, against a last-seen value seeded at
    /// registration, and on the main actor — the KVO callback itself can
    /// arrive on any thread.
    private func observeTimeControlStatus(of player: AVPlayer, generation: Int) {
        lastTransportStatus = player.timeControlStatus
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                guard status != self.lastTransportStatus else { return }
                self.lastTransportStatus = status
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

    /// How often the sampler reads the access log during playback. Fine
    /// enough to place a burst against ~6s segment boundaries (#99), cheap
    /// enough to be permanent: one off-main log snapshot per tick.
    private static let healthSampleInterval: Double = 2

    /// Log the access log's playback-health counters, permanently and at
    /// debug level (decision on #99): playback investigations recur, and the
    /// counters should already be in the log the next time one starts.
    ///
    /// Three counters, because they separate the two ways a session can look
    /// broken to a viewer. Dropped frames mean the decoder could not keep up.
    /// Stalls and overdue downloads mean the bytes did not arrive in time.
    /// A hitch with all three flat is neither — it is a presentation-timing
    /// defect, which is what #99 has been narrowing (the server's segments
    /// measured structurally clean: no drift, no GOP overlap, every fragment
    /// keyframe-led).
    ///
    /// Driven by a periodic time observer, not
    /// `newAccessLogEntryNotification`: that notification fires only when an
    /// *entry* is added, while the counters inside the current entry keep
    /// climbing unobserved — a session that stays within one entry (direct
    /// play, or HLS on a single variant) would log nothing however many
    /// frames it dropped, making silence meaningless. Sampling on playback
    /// time is the read that can't be starved, and it only runs while the
    /// player actually plays.
    ///
    /// The observer deliberately delivers on the sampler's own queue:
    /// `accessLog()` can block while log collection is in progress, so it
    /// must stay off the main thread — see `PlaybackHealthSampler`.
    private func observePlaybackHealth(of player: AVPlayer) {
        let sampler = PlaybackHealthSampler()
        healthSampler = sampler
        healthTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.healthSampleInterval, preferredTimescale: 600),
            queue: sampler.queue,
        ) { [weak player] time in
            // Weak: AVPlayer retains this block, so a strong capture is a
            // retain cycle.
            guard let item = player?.currentItem else { return }
            sampler.sampleOnQueue(item, atSeconds: time.seconds)
        }
        sampler.startTimelineWatch(of: player)
    }

    /// Playback-health counter state, confined to its own serial queue
    /// rather than the main actor, for two reasons:
    /// - `accessLog()` may block while log collection is in progress, so
    ///   reading it on the main thread could itself stall rendering — the
    ///   instrument must not cause what it measures.
    /// - Confining the last-logged counter to the sampling queue means no
    ///   actor hop, no generation fence, and no shared state: the engine
    ///   drops the sampler with the session and a fresh one starts at zero.
    ///
    /// Totals are summed across access-log events for the same reason
    /// `deliveryProgress()` sums bytes — the log accumulates one event per
    /// delivery period, each with its own counters. Each line carries the
    /// delta, the playback position, and the session total, which is what
    /// #99 correlates against segment boundaries.
    private final class PlaybackHealthSampler: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.justinlascelle.jellyshark.playback-health", qos: .utility)
        private var loggedDroppedFrames = 0
        private var loggedStalls = 0
        private var loggedOverdue = 0
        private var timelineTimer: DispatchSourceTimer?
        private var timelineBaseline: (media: Double, wall: Double)?

        /// Fine enough that a two-frame skip (~83 ms at 23.976 fps) stands
        /// clear of timer jitter, coarse enough to cost nothing: one
        /// `currentTime()` read per tick.
        private static let timelineInterval: DispatchTimeInterval = .milliseconds(250)
        /// Below this, the difference is timer jitter rather than a skip.
        private static let driftThreshold: Double = 0.040
        /// Above this, the playhead moved because of a seek, not a skip.
        private static let seekThreshold: Double = 1.0

        /// Must run on `queue`; the periodic time observer delivers there.
        func sampleOnQueue(_ item: AVPlayerItem, atSeconds seconds: Double) {
            dispatchPrecondition(condition: .onQueue(queue))
            let events = item.accessLog()?.events ?? []
            report(
                "[frames] dropped",
                total: Self.total(events) { $0.numberOfDroppedVideoFrames },
                against: &loggedDroppedFrames,
                atSeconds: seconds,
            )
            report(
                "[delivery] stalled",
                total: Self.total(events) { $0.numberOfStalls },
                against: &loggedStalls,
                atSeconds: seconds,
            )
            report(
                "[delivery] download overdue",
                total: Self.total(events) { $0.downloadOverdue },
                against: &loggedOverdue,
                atSeconds: seconds,
            )
        }

        /// Summed across events, excluding the `-1` an event reports for a
        /// counter it does not know.
        private static func total(
            _ events: [AVPlayerItemAccessLogEvent],
            _ counter: (AVPlayerItemAccessLogEvent) -> Int,
        ) -> Int {
            events.map(counter).filter { $0 >= 0 }.reduce(0, +)
        }

        /// Emits only when a total climbs, so silence means "none of these
        /// happened" rather than "not sampled".
        private func report(_ label: String, total: Int, against logged: inout Int, atSeconds seconds: Double) {
            guard total > logged else { return }
            let delta = total - logged
            logged = total
            AVFoundationPlayerEngine.logger.debug("\(label, privacy: .public) +\(delta) at \(seconds, format: .fixed(precision: 1))s (session total \(total))")
        }

        /// Report the playhead advancing by more or less than wall clock.
        ///
        /// The counters above cannot see a presentation-timing skip: nothing
        /// is dropped and nothing stalls, the picture simply jumps. What a
        /// skip *is*, measurably, is the playhead moving further in media
        /// time than the wall clock moved — so sample both and log the
        /// difference. This is the instrument #99 needs to place a hitch on
        /// the timeline exactly, instead of against a stopwatch.
        ///
        /// A wall-clock timer, not the periodic time observer: that observer
        /// fires on *media* time, so its media delta is 2 s by construction
        /// and a skip would be invisible in it.
        ///
        /// Only sampled at `rate == 1`. Pausing, seeking, and rebuffering all
        /// move the two clocks apart legitimately, so the baseline resets
        /// whenever the rate is anything else, and a media delta beyond
        /// `seekThreshold` is read as a seek rather than a skip.
        func startTimelineWatch(of player: AVPlayer) {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.timelineInterval, repeating: Self.timelineInterval)
            timer.setEventHandler { [weak player] in
                guard let player, let item = player.currentItem else { return }
                self.sampleTimelineOnQueue(item, rate: player.rate)
            }
            timelineTimer = timer
            timer.resume()
        }

        func stopTimelineWatch() {
            timelineTimer?.cancel()
            timelineTimer = nil
        }

        private func sampleTimelineOnQueue(_ item: AVPlayerItem, rate: Float) {
            dispatchPrecondition(condition: .onQueue(queue))
            let wall = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            let media = item.currentTime().seconds
            guard rate == 1, media.isFinite else {
                timelineBaseline = nil
                return
            }
            defer { timelineBaseline = (media: media, wall: wall) }
            guard let baseline = timelineBaseline else { return }
            let mediaDelta = media - baseline.media
            let wallDelta = wall - baseline.wall
            guard mediaDelta > 0, mediaDelta < Self.seekThreshold else { return }
            let drift = mediaDelta - wallDelta
            guard abs(drift) > Self.driftThreshold else { return }
            AVFoundationPlayerEngine.logger.debug("""
            [timeline] playhead jumped \(drift * 1000, format: .fixed(precision: 0))ms \
            at \(media, format: .fixed(precision: 3))s \
            (media +\(mediaDelta * 1000, format: .fixed(precision: 0))ms, \
            wall +\(wallDelta * 1000, format: .fixed(precision: 0))ms)
            """)
        }

        /// One last read after the item's playback ends, catching drops
        /// between the final periodic tick and the stop.
        func flush(_ item: AVPlayerItem) {
            queue.async { [self] in
                sampleOnQueue(item, atSeconds: item.currentTime().seconds)
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

import AetherEngine
import AVFoundation
import Combine
import Foundation
import JellyfinKit
import OSLog
import VideoToolbox
#if os(tvOS)
    import UIKit
#endif

// Spike #60 scaffolding (docs/spikes/60.md). Not for merge.

/// What the AVKit hosting needs from an engine and `PlayerEngine` does not
/// expose: the player to mount. Both engines conform so
/// `PlaybackContainerView` can hold either.
@MainActor
protocol AVPlayerHosting: AnyObject {
    var player: AVPlayer? { get }
}

extension AVFoundationPlayerEngine: AVPlayerHosting {}

/// Which engine a session uses. A launch argument, as the #226 spike did,
/// so the default path is untouched unless a run asks for the trial.
enum PlayerEngineSelection {
    static var usesAether: Bool {
        ProcessInfo.processInfo.arguments.contains("-spike-aether")
    }

    /// Vision Pro round, part A. False for step A1, true for step A2: tell
    /// the engine the headset presents Dolby Vision, which it cannot
    /// observe on visionOS. Flip it between the two builds.
    static let assertsDolbyVisionOnVisionOS = true

    /// E22: on tvOS, hand text subtitle tracks to AVKit to draw from the
    /// engine's renditions, and keep the app's overlay for image tracks
    /// and for sessions where AVKit's menu lists nothing. False restores
    /// E17's behaviour, where the app draws every cue.
    static let drawsTextSubtitlesWithAVKit = true

    /// True while AVKit is drawing the active subtitle, so the app's
    /// overlay leaves text cues alone and the two never draw one line twice.
    @MainActor static var avKitDrawsActiveSubtitle = false
}

/// Evidence for H4 on both engines: one footprint line every 5 s from the
/// first player onwards, so the figure after backing out is captured too.
@MainActor
enum SpikeFootprintLog {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")
    private static var started = false

    static func startIfNeeded() {
        guard !started else { return }
        started = true
        let engine = PlayerEngineSelection.usesAether ? "aether" : "default"
        Task {
            while true {
                logger.info("[spike] mem=\(megabytes())MB engine=\(engine, privacy: .public)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The app's physical footprint, the figure the system's memory limit is
    /// enforced against. 0 if the read fails.
    static func megabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}

/// Holds the one engine instance the upstream guide asks for ("one engine
/// per app"), created on first use so a session on the default engine never
/// pays for it.
@MainActor
enum AetherEngineHost {
    private static var instance: AetherEngine?

    static func shared() throws -> AetherEngine {
        if let instance {
            return instance
        }
        let engine = try AetherEngine()
        instance = engine
        return engine
    }
}

/// AetherEngine behind the `PlayerEngine` seam.
///
/// Covers what H3 to H5 need: load, transport, playhead, audio switch.
/// Subtitles go through `selectSubtitleInPlace` and the app's own overlay,
/// never AVKit's legible options, which stay empty here.
/// Left out on purpose: metadata enrichment, and the software route, where the
/// engine publishes no `AVPlayer` and the AVKit hosting shows nothing.
@MainActor
@Observable
final class AetherPlayerEngine: PlayerEngine, AVPlayerHosting {
    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Playback")
    /// The default engine's declaration, widened to what this engine reads
    /// itself, so the server answers direct play for sources AVFoundation
    /// would need remuxed or transcoded.
    nonisolated static let capabilities: PlaybackCapabilities = {
        var capabilities = AVFoundationPlayerEngine.capabilities
        capabilities.directPlay = [
            PlaybackCapabilities.DirectPlayRule(
                containers: ["mkv", "mp4", "m4v", "mov", "webm", "ts", "avi"],
                // AV1 and VP9 only where the device decodes them in
                // hardware. Without it the engine falls to software decode,
                // which could not keep real time on Apple TV (E15); left
                // undeclared, the server transcodes them as it does today.
                videoCodecs: ["hevc", "h264", "mpeg2video", "vc1"]
                    + (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? ["av1"] : [])
                    + (VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) ? ["vp9"] : []),
                audioCodecs: ["aac", "ac3", "eac3", "flac", "alac", "dts", "truehd", "opus", "mp3", "vorbis"],
            ),
        ]
        // No sample-entry or bit-depth conditions: the engine demuxes the
        // file itself. The range rule stays, widened, because a client that
        // declares none is treated as SDR-only and gets a tone-map.
        capabilities.videoCodecRules = [
            PlaybackCapabilities.VideoCodecRule(
                codec: "hevc",
                conditions: [
                    PlaybackCapabilities.VideoCodecCondition(
                        property: .videoRangeType,
                        comparison: .equalsAny,
                        value: "SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR|DOVIWithEL|DOVIWithHDR10Plus|DOVIWithELHDR10Plus",
                        isRequired: false,
                    ),
                ],
            ),
        ]
        // The engine decodes embedded subtitles and the app draws them, on
        // tvOS only. Declared as embedded so a subtitle the server picks by
        // default (the viewer's remembered language, say) does not cost the
        // session direct play for a burn-in (E16).
        #if os(tvOS)
            capabilities.subtitles = ["pgssub", "dvdsub", "dvbsub", "subrip", "srt", "ass", "ssa", "vtt", "webvtt", "mov_text"]
                .map { PlaybackCapabilities.SubtitleRule(format: $0, delivery: .embed) }
                + capabilities.subtitles
        #endif
        return capabilities
    }()

    nonisolated let streamingBitrateCap: Int?

    nonisolated var capabilities: PlaybackCapabilities {
        Self.capabilities.cappedStreamingBitrate(to: streamingBitrateCap)
    }

    /// Mirrors the engine's `currentAVPlayer`, which it republishes on
    /// reloads. Nil on the software route. Observed, so the hosting view
    /// follows it — whether that is safe on visionOS is H6.
    private(set) var player: AVPlayer?

    /// Non-nil while the session is on the engine's software route, where
    /// it draws into its own layer and publishes no `AVPlayer`. The
    /// container mounts `AetherPlayerSurface` on it: a picture with no
    /// transport controls, enough to see whether that route plays at all.
    private(set) var softwareRouteEngine: AetherEngine?

    /// The transport the session layer last asked for. The view model calls
    /// `play()` right after `load`, as AVPlayer allows; this engine drops a
    /// `play()` that lands mid-load (first run: clock parked at 0), so the
    /// request is replayed once the load returns.
    @ObservationIgnored private var wantsPlayback = false

    @ObservationIgnored private var pendingUpNextProposal: UpNextProposal?

    /// The resume point the session layer asked for while a load was still
    /// starting, and the start position that load actually used.
    @ObservationIgnored private var pendingResumeSeconds: Double?
    @ObservationIgnored private var appliedStartSeconds: Double?

    @ObservationIgnored var onEvent: ((PlayerEngineEvent) -> Void)?

    @ObservationIgnored private var engine: AetherEngine?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Stale-callback fence, as in `AVFoundationPlayerEngine`.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var sessionRequested = false
    @ObservationIgnored private var lastTransportStatus: PlaybackTransportStatus?
    @ObservationIgnored private var failureDescription: String?
    @ObservationIgnored private var hasReportedEnd = false

    /// Counts published changes from the engine. Stands in for a byte
    /// counter in `deliveryProgress`: the engine exposes none, and the
    /// first-frame watchdog only needs "something is still moving".
    @ObservationIgnored private var activityTicks: Int64 = 0

    @ObservationIgnored private(set) var observedPlayheadSeconds: Double?

    private(set) var audibleOptions: [AudibleOption] = []

    /// For each entry in AVKit's subtitle menu, the embedded subtitle
    /// position it stands for. Empty when the engine serves no renditions
    /// for this session, or when the menu did not match what was expected.
    private(set) var systemMenuSubtitlePositions: [Int] = []
    @ObservationIgnored private(set) var systemMenuSubtitlePick: SystemSubtitlePick = .none

    /// The menu entry the engine was last told to tick (AE#1052's marker).
    @ObservationIgnored private var markerPosition: Int? {
        didSet {
            markerSeenSelected = false
            markerSetAt = Date()
        }
    }

    /// When `markerPosition` was last set. The engine clears AVKit's
    /// selection itself just after a pick, while it prepares the track, and
    /// E22's second run showed `markerSeenSelected` alone does not fence
    /// that off: something re-selects the viewer's choice for an instant
    /// first. A viewer cannot reopen the menu and choose Off inside three
    /// seconds of a pick, so an empty selection that soon is the engine's.
    @ObservationIgnored private var markerSetAt = Date.distantPast
    private static let engineDeselectWindow: TimeInterval = 3

    /// Whether AVKit's selection has been seen sitting on `markerPosition`
    /// since it was set. "Nothing selected" only means the viewer chose Off
    /// once that has happened: before it, the engine itself clears the
    /// selection while it prepares the track, for a second or two when
    /// AVKit is to draw it. E22's first run read that gap as Off, so every
    /// track had to be picked twice.
    @ObservationIgnored private var markerSeenSelected = false
    @ObservationIgnored private weak var observedItem: AVPlayerItem?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleObserver: (any NSObjectProtocol)?
    @ObservationIgnored private weak var formatLoggedItem: AVPlayerItem?
    let legibleOptions: [LegibleOption] = []

    init(streamingBitrateCap: Int? = nil) {
        self.streamingBitrateCap = streamingBitrateCap
    }

    // MARK: - Lifecycle

    func load(url: URL, metadata _: PlayerSessionMetadata, loadsLegibleOptions _: Bool) {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        sessionRequested = true
        failureDescription = nil
        hasReportedEnd = false
        observedPlayheadSeconds = nil

        let engine: AetherEngine
        do {
            engine = try AetherEngineHost.shared()
        } catch {
            fail("engine init: \(error.localizedDescription)", cause: "aether init")
            return
        }
        if self.engine == nil {
            self.engine = engine
            // The app plays no audio of its own, so let the engine release
            // the session on a final stop, as its tvOS host setup advises.
            engine.deactivatesAudioSessionOnStop = true
            // No subtitle offset control in this app. Without this the
            // engine reads the file a second time to keep cues ready for
            // one: on a 20 GB title that reader pulled 765 MB in 30 s next
            // to the video's 452 MB (E17).
            engine.maximumSubtitleOffsetSeconds = 0
            subscribe(to: engine)
        }

        Self.logger.info("[aether] load \(AetherEngine.version, privacy: .public) gen=\(generation)")
        pendingResumeSeconds = nil
        appliedStartSeconds = nil
        resetSystemSubtitleMenu()
        loadTask = Task { [weak self] in
            do {
                // Let the view model's `seekForResume`, issued right after
                // `load`, register first: the engine rejects a seek before
                // its own load has begun (E10), so a resume point has to
                // ride in as the load's start position.
                await Task.yield()
                let start = self?.pendingResumeSeconds
                self?.appliedStartSeconds = start
                Self.logger.info("[aether] engine.load startPosition=\(start.map { String($0) } ?? "nil", privacy: .public)")
                // The view model calls `play()` itself once it has seeked
                // to the resume point, as it does on the default engine.
                var options = LoadOptions(autoplay: false)
                // Every subtitle track becomes an entry in AVKit's own
                // subtitle menu. The app still draws the cues; the entry
                // the viewer picked is ticked with a marker.
                options.prepareNativeSubtitles = true
                // The app has its own fallback, the server, so a refused
                // item should fail rather than move to software decode.
                options.escalatesToSoftwarePath = false
                #if os(visionOS)
                    if PlayerEngineSelection.assertsDolbyVisionOnVisionOS {
                        options.panelPresentsDolbyVision = true
                        options.panelIsInHDRMode = true
                    }
                    Self.logger.info("[aether] visionOS display assertion: dolbyVision=\(PlayerEngineSelection.assertsDolbyVisionOnVisionOS)")
                #endif
                try await engine.load(url: url, startPosition: start, options: options)
                guard let self, self.generation == generation else { return }
                Self.logger.info("[aether] loaded route=\(engine.videoRoute.rawValue, privacy: .public) tracks=\(engine.audioTracks.count)")
                onEvent?(.mediaSelectionOptionsLoaded)
                if wantsPlayback {
                    engine.play()
                }
            } catch is CancellationError {
                // A newer load or a stop took over; not a failure.
            } catch {
                guard let self, self.generation == generation else { return }
                fail(error.localizedDescription, cause: "aether load threw")
            }
        }
    }

    func play() {
        wantsPlayback = true
        engine?.play()
    }

    func pause() {
        wantsPlayback = false
        engine?.pause()
    }

    func seekForResume(toSeconds seconds: Double) async {
        guard let loadTask else {
            await engine?.seek(to: seconds)
            return
        }
        // Hand the position to the load in flight, wait for it, and seek
        // only if the load had already started without it.
        pendingResumeSeconds = seconds
        let generation = generation
        await loadTask.value
        guard self.generation == generation, appliedStartSeconds != seconds else { return }
        await engine?.seek(to: seconds)
    }

    func teardown() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        sessionRequested = false
        wantsPlayback = false
        engine?.stop()
        player = nil
        softwareRouteEngine = nil
        audibleOptions = []
        lastTransportStatus = nil
        resetSystemSubtitleMenu()
    }

    func suspendForRebuild() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        engine?.pause()
    }

    // MARK: - State

    var isLoaded: Bool {
        sessionRequested
    }

    var currentTimeSeconds: Double? {
        guard sessionRequested, let engine else { return nil }
        return engine.currentTime
    }

    var transportStatus: PlaybackTransportStatus {
        guard let engine else { return .paused }
        return Self.transportStatus(for: engine.playbackPhase)
    }

    var currentErrorDescription: String? {
        failureDescription
    }

    func deliveryProgress() -> DeliveryProgress {
        guard let engine else { return DeliveryProgress() }
        return DeliveryProgress(
            bufferedSeconds: max(0, engine.bufferedPosition - engine.currentTime),
            bytesTransferred: activityTicks,
        )
    }

    // MARK: - Media Selection

    var selectedAudiblePosition: Int? {
        guard let engine, let active = engine.activeAudioTrackIndex else { return nil }
        return engine.audioTracks.firstIndex { $0.id == active }
    }

    var selectedLegiblePosition: Int? {
        nil
    }

    /// Not the in-place flip the protocol describes: on this engine an
    /// audio switch is a session-preserving reload. What that does to the
    /// mounted player is H5.
    func selectAudible(position: Int) {
        guard let engine, engine.audioTracks.indices.contains(position) else {
            Self.logger.warning("[aether] selectAudible(\(position)) out of range")
            return
        }
        let track = engine.audioTracks[position]
        Self.logger.info("[aether] selectAudible position=\(position) id=\(track.id) codec=\(track.codec, privacy: .public)")
        engine.selectAudioTrack(index: track.id)
    }

    /// The overlay that draws the engine's cues exists on tvOS only.
    var drawsSubtitlesInApp: Bool {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }

    func selectSubtitleInPlace(embeddedPosition: Int?) -> Bool {
        guard let engine else { return false }
        guard let embeddedPosition else {
            engine.clearSubtitle()
            if PlayerEngineSelection.avKitDrawsActiveSubtitle {
                // The rendition was the display; take the request back.
                PlayerEngineSelection.avKitDrawsActiveSubtitle = false
                engine.setNativeSubtitleRendering(false)
                markerPosition = nil
            } else if markerPosition != nil {
                markerPosition = nil
                engine.setNativeSubtitleSelected(track: nil)
            }
            Self.logger.info("[aether] subtitle off")
            return true
        }
        let embedded = engine.subtitleTracks.filter { !$0.isExternal }
        guard embedded.indices.contains(embeddedPosition) else {
            Self.logger.warning("[aether] subtitle position \(embeddedPosition) out of range (\(embedded.count) embedded track(s))")
            return false
        }
        let track = embedded[embeddedPosition]
        Self.logger.info("[aether] subtitle position=\(embeddedPosition) id=\(track.id) codec=\(track.codec, privacy: .public) lang=\(track.language ?? "-", privacy: .public)")
        let menuPosition = systemMenuSubtitlePositions.firstIndex(of: embeddedPosition)
        let drawnByAVKit = PlayerEngineSelection.drawsTextSubtitlesWithAVKit
            && menuPosition != nil && !Self.isBitmapSubtitle(track.codec)
        if PlayerEngineSelection.avKitDrawsActiveSubtitle, !drawnByAVKit {
            // Leaving a track AVKit was drawing for one the app draws.
            engine.setNativeSubtitleRendering(false)
        }
        PlayerEngineSelection.avKitDrawsActiveSubtitle = drawnByAVKit
        engine.selectSubtitleTrack(index: track.id)
        guard let menuPosition else { return true }
        // Remembered either way, so the engine's own select, which echoes
        // through the selection notification, is not read as a new pick.
        markerPosition = menuPosition
        if drawnByAVKit {
            // The rendition is the display: selected for real, drawn by
            // AVKit in the system caption style.
            engine.setNativeSubtitleRendering(true)
            Self.logger.info("[aether] subtitle → AVKit draws menu position \(menuPosition)")
        } else {
            // Tick the track in AVKit's menu without having AVKit draw it.
            engine.setNativeSubtitleSelected(track: menuPosition, markerOnly: true)
            Self.logger.info("[aether] subtitle marker → menu position \(menuPosition)")
        }
        return true
    }

    // MARK: - Accepted video format

    /// Vision Pro round, part A: what the player itself reports it is
    /// playing, once per item. `dvh1` or `dvhe` means it accepted the
    /// stream as Dolby Vision; `hvc1` or `hev1` means plain HEVC. It says
    /// nothing about what the display then did with it.
    private func logAcceptedVideoFormat() {
        guard let item = engine?.currentAVPlayerItem, item !== formatLoggedItem else { return }
        formatLoggedItem = item
        Task { [weak self, weak item] in
            // An HLS item lists its tracks some time after it is mounted.
            for _ in 0 ..< 40 {
                guard let item, self?.formatLoggedItem === item else { return }
                for track in item.tracks {
                    guard let assetTrack = track.assetTrack, assetTrack.mediaType == .video,
                          let description = try? await assetTrack.load(.formatDescriptions).first
                    else { continue }
                    let code = CMFormatDescriptionGetMediaSubType(description)
                    let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
                    let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
                    let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "-"
                    let primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? "-"
                    let size = CMVideoFormatDescriptionGetDimensions(description)
                    // Step A1 showed `hvc1` for both titles: the engine
                    // signals Dolby Vision as a supplemental codec on an
                    // HEVC entry, so the fourCC cannot tell. The sample
                    // entry's own atoms can: `dvvC` or `dvcC` is the Dolby
                    // Vision configuration the player was handed.
                    let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
                    let atomNames = (atoms?.keys.sorted() ?? []).joined(separator: ",")
                    let hdrVideo = assetTrack.hasMediaCharacteristic(.containsHDRVideo)
                    Self.logger.info("[aether] accepted video format: \(fourCC, privacy: .public) \(size.width)x\(size.height) transfer=\(transfer, privacy: .public) primaries=\(primaries, privacy: .public) atoms=[\(atomNames, privacy: .public)] hdrVideo=\(hdrVideo)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            Self.logger.info("[aether] accepted video format: no video track listed after 10 s")
        }
    }

    // MARK: - AVKit's subtitle menu

    private func resetSystemSubtitleMenu() {
        if let legibleObserver {
            NotificationCenter.default.removeObserver(legibleObserver)
        }
        legibleObserver = nil
        legibleGroup = nil
        observedItem = nil
        formatLoggedItem = nil
        markerPosition = nil
        PlayerEngineSelection.avKitDrawsActiveSubtitle = false
        systemMenuSubtitlePick = .none
        systemMenuSubtitlePositions = []
    }

    private static func isBitmapSubtitle(_ codec: String) -> Bool {
        ["pgs", "dvd", "dvb", "xsub"].contains { codec.contains($0) }
    }

    private static func isClosedCaption(_ codec: String) -> Bool {
        ["eia", "608", "708"].contains { codec.contains($0) }
    }

    /// Watch the current item's subtitle selection. The engine lists its
    /// text renditions first and its image renditions after them, each in
    /// file order (`AetherEngine+Loading.swift`, 7.70.0), which is what
    /// the mapping below relies on. A menu that does not have exactly
    /// that many entries is left unmapped, and the app's menu stays.
    private func observeSystemSubtitleMenu() {
        guard let engine, let item = engine.currentAVPlayerItem, item !== observedItem else { return }
        if let legibleObserver {
            NotificationCenter.default.removeObserver(legibleObserver)
        }
        legibleObserver = nil
        legibleGroup = nil
        observedItem = item
        let generation = generation
        Task { [weak self] in
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.generation == generation, observedItem === item else { return }

            let embedded = engine.subtitleTracks.filter { !$0.isExternal }.enumerated()
            let text = embedded.filter { !Self.isBitmapSubtitle($0.element.codec) && !Self.isClosedCaption($0.element.codec) }
            let image = embedded.filter { Self.isBitmapSubtitle($0.element.codec) }
            let expected = (text.prefix(engine.nativeSubtitleTracks.count) + image).map(\.offset)
            let names = (group?.options ?? []).map(\.displayName).joined(separator: " | ")
            Self.logger.info("[aether] subtitle menu: \(group?.options.count ?? 0) entries, \(expected.count) expected, served=\(engine.nativeSubtitleRenditionsServed) [\(names, privacy: .public)]")

            guard let group, !expected.isEmpty, group.options.count == expected.count else {
                systemMenuSubtitlePositions = []
                return
            }
            legibleGroup = group
            systemMenuSubtitlePositions = expected
            legibleObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                object: item,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemSubtitleSelectionChanged()
                }
            }
        }
    }

    private var selectedMenuPosition: Int? {
        guard let item = observedItem, let group = legibleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group)
        else { return nil }
        return group.options.firstIndex(of: option)
    }

    private func systemSubtitleSelectionChanged() {
        // #395 capture: every selection change, with what the adapter
        // believed at that moment. The engine logs its own selects, so a
        // change with no engine line next to it came from AVKit.
        let sinceMarker = markerPosition == nil ? -1 : Int(Date().timeIntervalSince(markerSetAt) * 1000)
        Self.logger.info("[aether] #395 selection changed: selected=\(self.selectedMenuPosition.map(String.init) ?? "none", privacy: .public) marker=\(self.markerPosition.map(String.init) ?? "none", privacy: .public) seen=\(self.markerSeenSelected) sinceMarker=\(sinceMarker)ms")
        if let selected = selectedMenuPosition {
            // The engine's own select echoes here too.
            if selected == markerPosition {
                markerSeenSelected = true
                return
            }
            guard systemMenuSubtitlePositions.indices.contains(selected) else { return }
            reportSystemMenuPick(.embedded(systemMenuSubtitlePositions[selected]), cause: "menu position \(selected)")
        } else if markerPosition != nil, markerSeenSelected,
                  Date().timeIntervalSince(markerSetAt) > Self.engineDeselectWindow
        {
            // The engine deselects and reselects around its own marker
            // work, so "nothing selected" only means Off if it holds.
            let generation = generation
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.generation == generation,
                      markerPosition != nil, markerSeenSelected, selectedMenuPosition == nil
                else { return }
                reportSystemMenuPick(.off, cause: "menu Off")
            }
        }
    }

    private func reportSystemMenuPick(_ pick: SystemSubtitlePick, cause: String) {
        Self.logger.info("[aether] subtitle menu pick: \(String(describing: pick), privacy: .public) (\(cause, privacy: .public))")
        systemMenuSubtitlePick = pick
        #if os(visionOS)
            drawPickWithAVKit(pick)
        #else
            onEvent?(.mediaSelectionChanged)
        #endif
    }

    #if os(visionOS)
        /// Vision Pro round, part B. No overlay can live in AVKit's player
        /// on visionOS (#309), so the pick is handed back to AVKit to draw:
        /// the engine's rendition is selected for real, not as a marker,
        /// and the engine is told the rendition is the display. The session
        /// layer is not told, so the reported subtitle index stays as it
        /// was; this is a probe of whether anything draws at all.
        private func drawPickWithAVKit(_ pick: SystemSubtitlePick) {
            guard let engine else { return }
            switch pick {
            case .none:
                return
            case .off:
                markerPosition = nil
                engine.clearSubtitle()
                Self.logger.info("[aether] visionOS subtitle off")
            case let .embedded(position):
                let embedded = engine.subtitleTracks.filter { !$0.isExternal }
                guard embedded.indices.contains(position),
                      let menuPosition = systemMenuSubtitlePositions.firstIndex(of: position)
                else { return }
                let track = embedded[position]
                // Remembered so the engine's own select, which echoes
                // through the same notification, is not read as a new pick.
                markerPosition = menuPosition
                engine.selectSubtitleTrack(index: track.id)
                engine.setNativeSubtitleRendering(true)
                Self.logger.info("[aether] visionOS subtitle → AVKit draws menu position \(menuPosition) id=\(track.id) codec=\(track.codec, privacy: .public) lang=\(track.language ?? "-", privacy: .public)")
            }
        }
    #endif

    /// The engine clears a pick it did not make and forwards only its
    /// language (its `systemCaptionRequest` contract). Answer with the
    /// first menu entry in that language, unless the pick was already
    /// seen directly.
    private func answerSystemCaptionRequest(language: String?) {
        guard let engine, let language, markerPosition == nil else { return }
        let embedded = engine.subtitleTracks.filter { !$0.isExternal }
        let wanted = Self.baseLanguage(language)
        guard let menuPosition = systemMenuSubtitlePositions.firstIndex(where: { position in
            embedded.indices.contains(position) && Self.baseLanguage(embedded[position].language) == wanted
        }) else {
            Self.logger.info("[aether] caption request for \(language, privacy: .public): no matching track")
            return
        }
        let pick = SystemSubtitlePick.embedded(systemMenuSubtitlePositions[menuPosition])
        guard pick != systemMenuSubtitlePick else { return }
        reportSystemMenuPick(pick, cause: "caption request \(language)")
    }

    private static func baseLanguage(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return Locale.Language(identifier: tag).languageCode?.identifier(.alpha3) ?? tag.lowercased()
    }

    // MARK: - Metadata

    func applyEnrichedMetadata(chapterArtwork _: [Int: Data], posterData _: Data?) {}

    func setUpNextProposal(_ proposal: UpNextProposal?) {
        pendingUpNextProposal = proposal
        attachUpNextProposalIfPossible()
    }

    /// A cut-down copy of `AVFoundationPlayerEngine`'s attachment, re-run
    /// whenever the engine publishes a new item or duration: a reload (an
    /// audio switch) replaces the item, and the proposal lives on the item.
    /// Whether the card still presents after that is half of H5.
    private func attachUpNextProposalIfPossible() {
        #if os(tvOS)
            guard let item = engine?.currentAVPlayerItem else { return }
            guard let proposal = pendingUpNextProposal else {
                item.nextContentProposal = nil
                return
            }
            let endSeconds = item.duration.seconds
            guard item.duration.isNumeric, endSeconds.isFinite, endSeconds > proposal.leadSeconds else {
                Self.logger.info("[aether] upnext not attached: item duration \(endSeconds, format: .fixed(precision: 1))s")
                return
            }
            let content = UpNextContentProposal(
                contentTimeForTransition: CMTime(seconds: endSeconds - proposal.leadSeconds, preferredTimescale: 600),
                title: proposal.title,
                previewImage: proposal.previewImageData.flatMap(UIImage.init(data:)),
                episodeCode: proposal.episodeCode,
            )
            content.automaticAcceptanceInterval = -proposal.autoAcceptSeconds
            item.nextContentProposal = content
            Self.logger.info("[aether] upnext attached \"\(proposal.title, privacy: .public)\" end=\(endSeconds, format: .fixed(precision: 1))s")
        #endif
    }

    // MARK: - Engine subscriptions

    /// Subscribed once for the engine's lifetime, as its guide asks; the
    /// generation fence is not needed here because every sink reads the
    /// engine's current state rather than a captured session.
    private func subscribe(to engine: AetherEngine) {
        engine.$currentAVPlayer
            .sink { [weak self] player in
                guard let self, sessionRequested else { return }
                if self.player !== player {
                    Self.logger.info("[aether] currentAVPlayer \(player == nil ? "nil" : "published", privacy: .public) (was \(self.player == nil ? "nil" : "set", privacy: .public))")
                    self.player = player
                }
            }
            .store(in: &subscriptions)

        // `@Published` emits in willSet, so hop a turn before reading the
        // engine's current item back.
        engine.$currentAVPlayerItem.map { _ in () }
            .merge(with: engine.$duration.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, sessionRequested else { return }
                Self.logger.info("[aether] item or duration published; item=\(self.engine?.currentAVPlayerItem == nil ? "nil" : "set", privacy: .public)")
                attachUpNextProposalIfPossible()
                observeSystemSubtitleMenu()
                logAcceptedVideoFormat()
            }
            .store(in: &subscriptions)

        // Subscribed once, before the first load, as the engine's host
        // contract asks; nothing is replayed.
        engine.systemCaptionRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self, sessionRequested else { return }
                Self.logger.info("[aether] #395 engine caption request: lang=\(request.language ?? "none", privacy: .public) marker=\(self.markerPosition.map(String.init) ?? "none", privacy: .public)")
                answerSystemCaptionRequest(language: request.language)
            }
            .store(in: &subscriptions)

        engine.$videoRoute
            .sink { [weak self, weak engine] route in
                guard let self, sessionRequested else { return }
                softwareRouteEngine = route == .software ? engine : nil
            }
            .store(in: &subscriptions)

        engine.$playbackPhase
            .sink { [weak self] phase in
                self?.handle(phase: phase)
            }
            .store(in: &subscriptions)

        engine.$audioTracks
            .sink { [weak self] tracks in
                self?.audibleOptions = tracks.enumerated().map { position, track in
                    AudibleOption(position: position, displayName: track.name, languageTag: track.language)
                }
            }
            .store(in: &subscriptions)

        engine.$activeAudioTrackIndex
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, sessionRequested else { return }
                onEvent?(.mediaSelectionChanged)
            }
            .store(in: &subscriptions)

        engine.clock.$currentTime
            .sink { [weak self] time in
                guard let self, sessionRequested else { return }
                // Evidence for H3: a line every 5 s of playhead, read back
                // from the simulator log after a check.
                if Int(time / 5) != Int((observedPlayheadSeconds ?? -5) / 5) {
                    Self.logger.info("[aether] playhead \(time, format: .fixed(precision: 1))s route=\(engine.videoRoute.rawValue, privacy: .public) phase=\(String(describing: engine.playbackPhase), privacy: .public) mem=\(SpikeFootprintLog.megabytes())MB")
                }
                observedPlayheadSeconds = time
                activityTicks &+= 1
            }
            .store(in: &subscriptions)

        engine.clock.$bufferedPosition
            .sink { [weak self] _ in
                self?.activityTicks &+= 1
            }
            .store(in: &subscriptions)

        engine.$startupProgress
            .sink { [weak self] _ in
                self?.activityTicks &+= 1
            }
            .store(in: &subscriptions)
    }

    private func handle(phase: PlaybackPhase) {
        guard sessionRequested else { return }
        switch phase {
        case .ended:
            if !hasReportedEnd {
                hasReportedEnd = true
                onEvent?(.playedToEnd)
            }
        case let .error(message):
            fail(message, cause: "aether phase error")
        default:
            break
        }
        let status = Self.transportStatus(for: phase)
        if status != lastTransportStatus {
            lastTransportStatus = status
            onEvent?(.transportStatusChanged)
        }
    }

    private func fail(_ reason: String, cause: String) {
        guard failureDescription == nil else { return }
        failureDescription = reason
        Self.logger.error("[aether] failed (\(cause, privacy: .public)): \(reason, privacy: .public)")
        onEvent?(.deliveryFailed(reason: reason, cause: cause))
    }

    private static func transportStatus(for phase: PlaybackPhase) -> PlaybackTransportStatus {
        switch phase {
        case .playing: .playing
        case .paused, .idle, .ended, .error: .paused
        case .loading, .seeking, .rebuffering, .stalled: .waitingToPlay
        }
    }
}

import Foundation
import JellyfinKit

// MARK: - Transport Status

/// Engine-agnostic transport state: the three situations AVPlayer's
/// `timeControlStatus` distinguishes, without naming the AVFoundation type
/// so session-layer code and its tests stay engine-free.
public enum PlaybackTransportStatus: Equatable, Sendable {
    case playing
    case paused
    /// A rate was requested but nothing is rendering yet — startup or a
    /// rebuffer. Whether that is a failure is the session layer's call
    /// (see `PlaybackViewModel.firstFrameVerdict`).
    case waitingToPlay
}

// MARK: - Events

/// One-way notifications from the engine to the session layer.
///
/// Delivered synchronously on the main actor through
/// `PlayerEngine.onEvent` — a single closure, not a stream or delegate,
/// because exactly one consumer exists and synchronous delivery keeps the
/// order deterministic under test.
public enum PlayerEngineEvent: Sendable {
    /// The transport moved between playing/paused/waiting. The session
    /// layer reports a progress heartbeat so the server's session view
    /// follows pause and resume promptly.
    case transportStatusChanged

    /// The current item played to its end.
    case playedToEnd

    /// Delivery failed outright: the item's status went to failed, or the
    /// engine gave up on a stream that had been playing. `reason` is the
    /// engine's own error description when it has one; `cause` names the
    /// signal for the log line.
    case deliveryFailed(reason: String?, cause: String)

    /// The current media selection changed underneath the app — on tvOS the
    /// native transport-bar pickers flip renditions directly on the player
    /// (#89). The session layer reconciles its stream indices against the
    /// engine's selection state.
    case mediaSelectionChanged

    /// The audible/legible option lists for the freshly loaded stream are
    /// in place. Reconciliation stays disarmed until this arrives — a
    /// change notification before then could not be mapped to a Jellyfin
    /// stream index.
    case mediaSelectionOptionsLoaded
}

// MARK: - Session Metadata

/// What the engine should present for the playing item, as plain values.
///
/// HLS remux/transcode streams carry none of the source file's embedded
/// metadata, so the player's title view, Info tab, and chapter panel are
/// reconstructed from Jellyfin data. The session layer describes that data
/// here; how it reaches the player UI is the engine's business.
public struct PlayerSessionMetadata: Sendable {
    public let item: MediaItem
    public let chapters: [Chapter]
    public let durationSeconds: Double?

    public init(item: MediaItem, chapters: [Chapter], durationSeconds: Double?) {
        self.item = item
        self.chapters = chapters
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Up Next Proposal

/// The next-episode data an engine needs to present a *pre-roll* Up Next
/// prompt, as plain values.
///
/// The session layer resolves this during playback (title, artwork) and
/// hands it down; the engine turns it into whatever native mechanism its
/// platform provides — `AVContentProposal` on tvOS, which AVKit presents
/// inside its own view-controller hierarchy ahead of the item's end (#186).
/// Kept engine-free (no AVKit/UIKit types) so the session layer and its
/// tests stay platform-agnostic.
public struct UpNextProposal: Equatable, Sendable {
    /// Title shown on the prompt — the next episode's name, without the
    /// season/episode code baked in.
    public let title: String

    /// The compact season/episode code ("S2E4"), shown as its own eyebrow
    /// line so the title keeps its full width (the same call
    /// `landscapeShelfItem` documents); nil when the item carries no numbers.
    public let episodeCode: String?

    /// Decoded preview image (poster/thumb) bytes, nil when unavailable.
    /// The engine decodes it into its platform's image type.
    public let previewImageData: Data?

    /// How many seconds before the item's end to present the prompt.
    public let leadSeconds: Double

    /// How many seconds before the item's end the prompt auto-accepts if
    /// the viewer does nothing. Kept shorter than `leadSeconds` so the
    /// natural ending stays on screen for a beat before cutting away.
    public let autoAcceptSeconds: Double

    public init(
        title: String,
        episodeCode: String?,
        previewImageData: Data?,
        leadSeconds: Double,
        autoAcceptSeconds: Double,
    ) {
        self.title = title
        self.episodeCode = episodeCode
        self.previewImageData = previewImageData
        self.leadSeconds = leadSeconds
        self.autoAcceptSeconds = autoAcceptSeconds
    }
}

// MARK: - Delivery Progress

/// Evidence that media is still arriving, sampled by the session layer's
/// first-frame watchdog at each deadline.
///
/// Two measures because neither covers both delivery shapes:
///
/// `bufferedSeconds` is the natural one, but it needs a *timeline* — a
/// progressively-downloaded direct-play file reports no loaded ranges
/// until AVPlayer has read enough of the container to know its duration,
/// so bytes can be pouring in with this still at zero. That is what a
/// conditioner run showed: a throttled direct play failed with no loaded
/// ranges ever appearing.
///
/// `bytesTransferred` has no such precondition. It is the honest "is the
/// socket moving" counter, and it is what saves the direct-play case.
public struct DeliveryProgress: Equatable, Sendable {
    public var bufferedSeconds: Double = 0
    public var bytesTransferred: Int64 = 0

    public init(bufferedSeconds: Double = 0, bytesTransferred: Int64 = 0) {
        self.bufferedSeconds = bufferedSeconds
        self.bytesTransferred = bytesTransferred
    }

    /// Whether anything at all advanced since `other`.
    public func advanced(since other: Self) -> Bool {
        bufferedSeconds > other.bufferedSeconds || bytesTransferred > other.bytesTransferred
    }
}

// MARK: - Engine

/// The rendering/transport half of playback: what actually decodes and
/// draws. The session half — what item, what position, what tracks, and
/// reporting all of it to the server — lives in `PlaybackViewModel`, which
/// talks only to this protocol (#85).
///
/// Public so an engine can live in its own package (#199). The app target
/// registers it through `PlayerEngineRegistry`; `PlaybackContainerView`
/// hosts it through `PlayerEngineHosting`. `AVFoundationPlayerEngine` is the
/// default whenever no registered engine is supplied.
///
/// The requirements below that are stated as obligations are behaviour the
/// session layer relies on and the signatures cannot show. AVPlayer meets
/// each one natively; a second engine has to meet them on purpose.
@MainActor
public protocol PlayerEngine: AnyObject {
    /// What this engine decodes and renders. The `DeviceProfile` sent with
    /// every PlaybackInfo request is derived from this declaration, so the
    /// server negotiates against the engine that will actually decode the
    /// stream — a second engine sends its own profile with no other change.
    var capabilities: PlaybackCapabilities { get }

    /// The viewer's streaming ceiling in bits per second (#168), or nil at
    /// the default tier.
    ///
    /// Reported separately from `capabilities`, whose ceiling is already the
    /// narrowed one: delivery selection has to tell a cap the *viewer* set
    /// from the engine's own declared 120 Mbps, and only the former is a
    /// reason to refuse a delivery that ignores bitrate.
    var streamingBitrateCap: Int? { get }

    /// Event sink, invoked synchronously on the main actor. Set once by the
    /// session layer before the first `load`.
    var onEvent: ((PlayerEngineEvent) -> Void)? { get set }

    // MARK: Lifecycle

    /// Start playing `url` and attach every observer.
    ///
    /// Obligations:
    /// - The failure observers must be armed before this returns (#151).
    ///   Until they exist a delivery failure has no way to reach the session
    ///   layer, and the caller's next steps include network awaits.
    /// - When a player already exists — a rebuild after `suspendForRebuild`
    ///   — replace the *item* inside it rather than construct a new player
    ///   (#217). Handing a mounted `AVPlayerViewController` a different
    ///   `AVPlayer` costs its RealityKit video entity the player component
    ///   on visionOS.
    ///
    /// - Parameter loadsLegibleOptions: whether to load the legible
    ///   media-selection group. The session layer skips it on direct play
    ///   (no renditions; the embedded defaults are left to the player).
    func load(url: URL, metadata: PlayerSessionMetadata, loadsLegibleOptions: Bool)

    /// Obligation: honour a call that arrives while the stream is still
    /// being prepared, by starting once it is ready. The session layer calls
    /// this once, after `load` and any resume seek, without waiting for the
    /// stream, and does not repeat it (#60, E3).
    func play()

    func pause()

    /// Seek to a resume position: frame-exact before, tolerant after, so
    /// resume never lands earlier than the viewer left off.
    ///
    /// Obligation: honour a seek issued in the same instant as `load`,
    /// before the stream is ready, rather than dropping it. The session
    /// layer awaits this before calling `play()`; a dropped seek resumes
    /// every session from zero (#60, E10).
    func seekForResume(toSeconds seconds: Double) async

    /// Pause, drop the player, and remove every observer. Idempotent.
    func teardown()

    /// Pause and silence the current session but *hold* the player, for a
    /// stream rebuild.
    ///
    /// Removes every observer and invalidates in-flight callbacks, as
    /// `teardown` does, but keeps the player (and the metadata `load` was
    /// given) so the hosting view goes on rendering its last frame while the
    /// replacement stream builds. On visionOS that is not cosmetic —
    /// unmounting the player view while AVKit's fullscreen window is up
    /// leaves the app's own window hidden with nothing to restore it (#183).
    ///
    /// `load` re-arms from scratch (it removes observers and bumps its own
    /// generation), so this exists only to stop the outgoing session's events
    /// during the window before the successor arrives.
    ///
    /// Obligation: `isLoaded` stays true across it. The session layer routes
    /// on it (`applySelection`, `retry()`), so an engine must not report
    /// itself unloaded mid-rebuild.
    func suspendForRebuild()

    // MARK: State

    var isLoaded: Bool { get }

    /// The playhead, read live. Exact, and expensive in the wrong moment:
    /// AVFoundation answers it with a synchronous XPC round trip to
    /// mediaserverd, which a wedged media server can hold for seconds
    /// (13 s measured — #188). Right for the one-off reads that need the
    /// exact value — a stop's final position, a rebuild's anchor — and
    /// wrong for anything periodic. See `observedPlayheadSeconds`.
    var currentTimeSeconds: Double? { get }

    /// The playhead as last *reported* by the engine — a mirror fed by a
    /// periodic time observer, never a live read. At most one observer
    /// interval stale while playing, and frozen while playback is: the
    /// observer fires only as time advances (and on seeks and rate
    /// changes), so a stall is visible here as a value that stops moving.
    /// This is what the reporting heartbeat and the outage monitor read
    /// (#188). Nil until the engine has reported a position for the
    /// current load.
    var observedPlayheadSeconds: Double? { get }

    var transportStatus: PlaybackTransportStatus { get }

    /// The engine's error for the current session, non-nil only once
    /// playback has failed outright.
    var currentErrorDescription: String? { get }

    /// Sampled on demand by the session layer's first-frame watchdog.
    func deliveryProgress() -> DeliveryProgress

    // MARK: Media Selection

    /// The audible options of the current stream, distilled for matching;
    /// empty until loaded (and empty when the stream carries no group).
    var audibleOptions: [AudibleOption] { get }

    /// The legible options of the current stream; empty until loaded, and
    /// always empty when `load` was told not to load them.
    ///
    /// Deliberately read-only, with no select-or-clear counterpart: AVKit
    /// owns text subtitles — its picker, the rendition's DEFAULT/AUTOSELECT
    /// flags, and the viewer's system caption preference decide what
    /// renders. The app used to select and clear, and the clear
    /// (`select(nil)`) latched AVKit's subtitle display off process-wide,
    /// surviving full player recreation (#91). No engine API may reintroduce
    /// that path — including the engine-drawn subtitle members below, which
    /// must never reach AVKit's legible group.
    var legibleOptions: [LegibleOption] { get }

    /// Position of the currently selected audible option, in
    /// `audibleOptions` terms; nil when nothing is selected or loaded.
    var selectedAudiblePosition: Int? { get }

    /// Position of the currently selected legible option; nil when
    /// subtitles are off or the group is not loaded.
    var selectedLegiblePosition: Int? { get }

    /// Select the audible option at `position` in place — the same flip
    /// AVKit's native picker performs: no rebuild, no interruption. The
    /// session layer routes a direct-play audio switch here so the session
    /// keeps direct play instead of dropping to a server remux (#187).
    ///
    /// Safe where a legible counterpart is not: the #91 latch is tripped by
    /// *clearing* the legible selection, and audio is never legitimately
    /// deselected — which is why this takes a non-optional position.
    /// A position outside `audibleOptions` is refused.
    func selectAudible(position: Int)

    // MARK: Engine-Drawn Subtitles

    /// Whether this engine decodes a direct-played file's embedded subtitles
    /// itself and draws them through the app. Defaults to false, which keeps
    /// every member in this group inert.
    ///
    /// When true, and only while the session direct plays, the session
    /// layer never asks the server for a subtitle (an index sent there would
    /// burn an image track in, or drop direct play), lists the embedded
    /// tracks AVKit's menu does not in the app's own menu, and routes every
    /// pick through `selectSubtitleInPlace`.
    var drawsSubtitlesInApp: Bool { get }

    /// Show the embedded subtitle at `embeddedPosition`, or none for nil.
    ///
    /// `embeddedPosition` counts only the source's embedded subtitle streams
    /// (sidecar files excluded), in the order Jellyfin lists them. This is
    /// the engine's own cue pipeline: it must not select or clear AVKit's
    /// legible group, so the #91 latch is never in play. Called after each
    /// pick and again once `mediaSelectionOptionsLoaded` arrives, since a
    /// fresh load starts with subtitles off.
    ///
    /// - Returns: false when the engine cannot map or show the track. The
    ///   session layer logs the refusal, so a pick that does nothing is
    ///   explainable from the log.
    func selectSubtitleInPlace(embeddedPosition: Int?) -> Bool

    /// The embedded subtitle positions AVKit's own subtitle menu lists for
    /// this session. The app's menu leaves those out, so no track is offered
    /// twice.
    var systemMenuSubtitlePositions: [Int] { get }

    /// What the viewer last chose in AVKit's subtitle menu, read after a
    /// `mediaSelectionChanged` event.
    var systemMenuSubtitlePick: SystemSubtitlePick { get }

    // MARK: Metadata

    /// Upgrade the current item's presentation with fetched artwork —
    /// chapter thumbnails keyed by `Chapter.imageIndex`, and the poster.
    /// The session layer owns the fetching (it holds the client); the
    /// engine owns the application.
    func applyEnrichedMetadata(chapterArtwork: [Int: Data], posterData: Data?)

    // MARK: Up Next (tvOS)

    /// Attach — or clear, with nil — a pre-roll Up Next proposal to the
    /// current item.
    ///
    /// tvOS-only in effect: AVKit presents `AVContentProposal` inside its own
    /// view-controller hierarchy ahead of the item's end, which is the focus
    /// environment a SwiftUI sibling overlay could never take from a live
    /// player (#186). The engine builds the proposal against the *concrete*
    /// player item's duration — an item with no known duration presents
    /// nothing. A no-op on visionOS, where the post-roll SwiftUI overlay
    /// stands in pending #182.
    func setUpNextProposal(_ proposal: UpNextProposal?)
}

/// A choice made in AVKit's subtitle menu, in the terms of an engine that
/// draws subtitles through the app.
public enum SystemSubtitlePick: Equatable, Sendable {
    /// Nothing to act on.
    case none
    case off
    /// The embedded subtitle stream at this position, counted as
    /// `PlayerEngine.selectSubtitleInPlace(embeddedPosition:)` counts.
    case embedded(Int)
}

public extension PlayerEngine {
    /// No cap unless an engine says otherwise, so conforming types that
    /// predate #168 — and the test double — need no change.
    var streamingBitrateCap: Int? {
        nil
    }

    /// Engines draw no subtitles of their own unless they say so; AVKit's
    /// legible group stays in charge.
    var drawsSubtitlesInApp: Bool {
        false
    }

    func selectSubtitleInPlace(embeddedPosition _: Int?) -> Bool {
        false
    }

    var systemMenuSubtitlePositions: [Int] {
        []
    }

    var systemMenuSubtitlePick: SystemSubtitlePick {
        .none
    }
}

import Foundation
import JellyfinKit

// MARK: - Transport Status

/// Engine-agnostic transport state: the three situations AVPlayer's
/// `timeControlStatus` distinguishes, without naming the AVFoundation type
/// so session-layer code and its tests stay engine-free.
enum PlaybackTransportStatus: Equatable {
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
enum PlayerEngineEvent {
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
struct PlayerSessionMetadata {
    let item: MediaItem
    let chapters: [Chapter]
    let durationSeconds: Double?
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
struct UpNextProposal: Equatable {
    /// Title shown on the prompt — the next episode's name, without the
    /// season/episode code baked in.
    let title: String

    /// The compact season/episode code ("S2E4"), shown as its own eyebrow
    /// line so the title keeps its full width (the same call
    /// `landscapeShelfItem` documents); nil when the item carries no numbers.
    let episodeCode: String?

    /// Decoded preview image (poster/thumb) bytes, nil when unavailable.
    /// The engine decodes it into its platform's image type.
    let previewImageData: Data?

    /// How many seconds before the item's end to present the prompt.
    let leadSeconds: Double

    /// How many seconds before the item's end the prompt auto-accepts if
    /// the viewer does nothing. Kept shorter than `leadSeconds` so the
    /// natural ending stays on screen for a beat before cutting away.
    let autoAcceptSeconds: Double
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
struct DeliveryProgress: Equatable {
    var bufferedSeconds: Double = 0
    var bytesTransferred: Int64 = 0

    /// Whether anything at all advanced since `other`.
    func advanced(since other: Self) -> Bool {
        bufferedSeconds > other.bufferedSeconds || bytesTransferred > other.bytesTransferred
    }
}

// MARK: - Engine

/// The rendering/transport half of playback: what actually decodes and
/// draws. The session half — what item, what position, what tracks, and
/// reporting all of it to the server — lives in `PlaybackViewModel`, which
/// talks only to this protocol (#85).
///
/// `AVFoundationPlayerEngine` is the sole implementation. A second engine
/// would conform here, declare its own capabilities (#85 PR2), and provide
/// its own hosting view where `PlaybackContainerView` builds the AVKit one.
@MainActor
protocol PlayerEngine: AnyObject {
    /// What this engine decodes and renders. The `DeviceProfile` sent with
    /// every PlaybackInfo request is derived from this declaration, so the
    /// server negotiates against the engine that will actually decode the
    /// stream — a second engine sends its own profile with no other change.
    var capabilities: PlaybackCapabilities { get }

    /// Event sink, invoked synchronously on the main actor. Set once by the
    /// session layer before the first `load`.
    var onEvent: ((PlayerEngineEvent) -> Void)? { get set }

    // MARK: Lifecycle

    /// Create a fresh player for `url` and attach every observer.
    ///
    /// Obligation (#151): the failure observers must be armed before this
    /// returns. Until they exist a delivery failure has no way to reach the
    /// session layer, and the caller's next steps include network awaits.
    ///
    /// - Parameter loadsLegibleOptions: whether to load the legible
    ///   media-selection group. The session layer skips it on direct play
    ///   (no renditions; the embedded defaults are left to the player).
    func load(url: URL, metadata: PlayerSessionMetadata, loadsLegibleOptions: Bool)

    func play()
    func pause()

    /// Seek to a resume position: frame-exact before, tolerant after, so
    /// resume never lands earlier than the viewer left off.
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
    /// during the window before the successor arrives. `isLoaded` stays true
    /// across it, deliberately: the session layer routes on it.
    func suspendForRebuild()

    // MARK: State

    var isLoaded: Bool { get }
    var currentTimeSeconds: Double? { get }
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
    /// that path.
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

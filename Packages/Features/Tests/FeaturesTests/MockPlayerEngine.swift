@testable import Features
import Foundation

/// The `PlayerEngine` stub for the playback suites: records every call,
/// serves settable state, and lets tests drive the session layer by
/// sending engine events synchronously — which is the point of the seam
/// (#85): the view model's policy becomes testable without AVFoundation.
@MainActor
final class MockPlayerEngine: PlayerEngine {
    /// The real AVFoundation declaration by default, so resolution flows
    /// exercise the same negotiation values production does
    var capabilities: PlaybackCapabilities = AVFoundationPlayerEngine.capabilities

    var onEvent: ((PlayerEngineEvent) -> Void)?

    // Recorded calls
    private(set) var loadRequests: [(url: URL, metadata: PlayerSessionMetadata, loadsLegibleOptions: Bool)] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var teardownCount = 0
    private(set) var resumeSeeks: [Double] = []
    private(set) var enrichedMetadataApplications: [(chapterArtwork: [Int: Data], posterData: Data?)] = []

    var lastLoadedURL: URL? {
        loadRequests.last?.url
    }

    var lastMetadata: PlayerSessionMetadata? {
        loadRequests.last?.metadata
    }

    // Settable state
    private(set) var isLoaded = false
    var currentTimeSeconds: Double?
    /// Updated by `play()`/`pause()` for realism; no event is emitted — the
    /// real engine's events come from KVO, so tests send them explicitly
    var transportStatus: PlaybackTransportStatus = .paused
    var currentErrorDescription: String?
    var deliveryProgressValue = DeliveryProgress()
    var audibleOptions: [AudibleOption] = []
    var legibleOptions: [LegibleOption] = []
    var selectedAudiblePosition: Int?
    var selectedLegiblePosition: Int?

    func load(url: URL, metadata: PlayerSessionMetadata, loadsLegibleOptions: Bool) {
        loadRequests.append((url, metadata, loadsLegibleOptions))
        isLoaded = true
    }

    /// Fired inside `play()`, which lands in the window where both of the
    /// session layer's event gates are still closed — after `load` armed
    /// the real engine's observers, before `armDeliveryFailureDetection`
    /// and the start report open them. The only hook a test has on that
    /// window.
    var onPlay: (() -> Void)?

    func play() {
        playCount += 1
        transportStatus = .playing
        onPlay?()
    }

    func pause() {
        pauseCount += 1
        transportStatus = .paused
    }

    func seekForResume(toSeconds seconds: Double) async {
        resumeSeeks.append(seconds)
    }

    func teardown() {
        teardownCount += 1
        isLoaded = false
        currentTimeSeconds = nil
        transportStatus = .paused
        currentErrorDescription = nil
        audibleOptions = []
        legibleOptions = []
        selectedAudiblePosition = nil
        selectedLegiblePosition = nil
    }

    func deliveryProgress() -> DeliveryProgress {
        deliveryProgressValue
    }

    func applyEnrichedMetadata(chapterArtwork: [Int: Data], posterData: Data?) {
        enrichedMetadataApplications.append((chapterArtwork, posterData))
    }

    /// Deliver an event to the session layer, synchronously, as the real
    /// engine would from the main actor
    func send(_ event: PlayerEngineEvent) {
        onEvent?(event)
    }
}

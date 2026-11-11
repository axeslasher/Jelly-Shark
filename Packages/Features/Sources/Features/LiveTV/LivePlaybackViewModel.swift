import Foundation
import JellyfinKit
import Observation
import OSLog

/// One Live TV viewing session: opens a channel's stream, keeps the server
/// told that it is being watched, and releases it afterwards.
///
/// Separate from `PlaybackViewModel` on purpose. A live stream has no resume
/// position, no duration, no chapters, no track rebuilds and no next
/// episode, which is most of what that type manages; sharing it would put a
/// live branch in every one of those paths.
@Observable
@MainActor
final class LivePlaybackViewModel {
    enum State: Equatable {
        case loading
        case playing
        case failed(String)
    }

    private(set) var state: State = .loading

    /// The channel being watched; changes when the viewer picks another
    /// from the guide strip.
    private(set) var channel: LiveChannel

    /// The open stream the player should be showing, nil while one loads
    private(set) var session: LiveStreamSession?

    private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "LiveTV")

    private let client: any JellyfinClientProtocol
    private let capabilities: PlaybackCapabilities
    private let progressInterval: Duration
    private let clock = ContinuousClock()

    /// The channel `session` was opened for, which its reports must name
    private var sessionChannelId: String?
    private var startedAt: ContinuousClock.Instant?
    private var progressTask: Task<Void, Never>?
    private var hasStopped = false

    /// Bumped per open. An open that finds it moved on has been replaced by
    /// a channel change or a stop, and must release what it opened.
    private var generation = 0

    init(
        client: any JellyfinClientProtocol,
        channel: LiveChannel,
        capabilities: PlaybackCapabilities,
        progressInterval: Duration = .seconds(10),
    ) {
        self.client = client
        self.channel = channel
        self.capabilities = capabilities
        self.progressInterval = progressInterval
    }

    func start() async {
        await open()
    }

    /// Leave the current channel and open another, in place.
    func switchChannel(to newChannel: LiveChannel) async {
        guard newChannel.id != channel.id, !hasStopped else { return }
        // Claimed before the release below suspends, so a second pick made
        // meanwhile supersedes this one instead of racing it.
        generation += 1
        let claimed = generation
        channel = newChannel
        state = .loading
        await releaseSession()
        guard claimed == generation else { return }
        await open()
    }

    func retry() async {
        guard !hasStopped else { return }
        await releaseSession()
        await open()
    }

    /// The player gave up on the stream.
    ///
    /// - Parameter url: the stream that failed. A failure from a stream this
    ///   session has already left is that stream being closed, not an error.
    func playerFailed(url: URL, reason: String?) {
        guard url == session?.url, state == .playing else { return }
        // The player's own wording can quote the stream address, which
        // carries the access token: redacted for the log and the screen alike.
        let reason = reason.map(PlaybackLog.redacting)
        Self.logger.error("[live] player failed on \"\(self.channel.name, privacy: .public)\": \(reason ?? "unknown", privacy: .public)")
        state = .failed(reason ?? String(
            localized: "liveTV.player.streamStopped",
            bundle: #bundle,
            comment: "Error shown when a live TV stream stops unexpectedly.",
        ))
    }

    /// Release the stream and end the session. Idempotent.
    func stop() async {
        guard !hasStopped else { return }
        hasStopped = true
        generation += 1
        await releaseSession()
    }

    // MARK: - Private

    private func open() async {
        generation += 1
        let opening = generation
        state = .loading

        do {
            let opened = try await client.openLiveStream(channelId: channel.id, capabilities: capabilities)
            guard opening == generation else {
                // Opened for a session that has moved on. No playback was
                // ever reported for it, so the stopped report cannot release
                // it; close it directly.
                await client.closeLiveStream(opened)
                return
            }
            session = opened
            sessionChannelId = channel.id
            startedAt = clock.now
            state = .playing
            startReporting(opened)
        } catch {
            guard opening == generation else { return }
            Self.logger.error("[live] open failed for \"\(self.channel.name, privacy: .public)\": \(PlaybackLog.error(error), privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Report the start, then a heartbeat until the session is released.
    ///
    /// From here the session counts as reported, whether or not the start
    /// report lands: its release is the stopped report, which the server
    /// honours without a start.
    private func startReporting(_ session: LiveStreamSession) {
        progressTask?.cancel()
        progressTask = Task { [client, channel, progressInterval] in
            try? await client.reportPlaybackStart(
                itemId: channel.id,
                mediaSourceId: session.mediaSourceId,
                playSessionId: session.playSessionId,
                positionTicks: 0,
                playMethod: .transcode,
                audioStreamIndex: nil,
                subtitleStreamIndex: nil,
            )
            while !Task.isCancelled {
                try? await Task.sleep(for: progressInterval)
                guard !Task.isCancelled else { return }
                try? await client.reportPlaybackProgress(
                    itemId: channel.id,
                    mediaSourceId: session.mediaSourceId,
                    playSessionId: session.playSessionId,
                    positionTicks: self.elapsedTicks(),
                    playMethod: .transcode,
                    isPaused: false,
                    audioStreamIndex: nil,
                    subtitleStreamIndex: nil,
                )
            }
        }
    }

    /// End the adopted session server-side: the stopped report releases the
    /// tuner, and the encode is stopped explicitly as the library player does.
    private func releaseSession() async {
        progressTask?.cancel()
        progressTask = nil
        guard let session else { return }
        // Not `channel.id`: a channel change has already moved that on.
        let itemId = sessionChannelId ?? channel.id
        self.session = nil
        sessionChannelId = nil
        let position = elapsedTicks()
        startedAt = nil

        do {
            try await client.reportPlaybackStopped(
                itemId: itemId,
                mediaSourceId: session.mediaSourceId,
                playSessionId: session.playSessionId,
                positionTicks: position,
            )
        } catch {
            Self.logger.error("[live] stopped report failed: \(PlaybackLog.error(error), privacy: .public)")
        }
        if let playSessionId = session.playSessionId {
            await client.stopEncoding(playSessionId: playSessionId)
        }
    }

    private func elapsedTicks() -> Int64 {
        guard let startedAt else { return 0 }
        let elapsed = clock.now - startedAt
        return PlaybackTicks.ticks(fromSeconds: Double(elapsed.components.seconds))
    }
}

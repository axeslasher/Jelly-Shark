@testable import Features
import Foundation
import JellyfinKit
import Testing

/// Waits here are on recorded calls, so one that never comes ends the test
/// at its time limit.
@Suite("LivePlaybackViewModel", .timeLimit(.minutes(1)))
@MainActor
struct LivePlaybackViewModelTests {
    private let trek = LiveChannel(id: "ch4", name: "Star Trek", number: "4")
    private let comfort = LiveChannel(id: "ch5", name: "Comfort", number: "5")

    private func makeModel(_ client: MockJellyfinClient, channel: LiveChannel? = nil) -> LivePlaybackViewModel {
        LivePlaybackViewModel(
            client: client,
            channel: channel ?? trek,
            capabilities: AVFoundationPlayerEngine.capabilities,
            // Long enough that no heartbeat lands inside a test
            progressInterval: .seconds(3600),
        )
    }

    /// The start report is sent from a child task; wait for the call itself.
    private func waitForStartReport(_ client: MockJellyfinClient, count: Int = 1) async {
        await client.recorded { $0.startReports.count >= count }
    }

    /// A release ends with the encode being stopped, after its stopped report.
    private func waitForRelease(_ client: MockJellyfinClient, count: Int = 1) async {
        await client.recorded { $0.stopReports.count >= count && $0.stopEncodingCalls.count >= count }
    }

    @Test("Starting opens the channel's stream and reports it as playing")
    func startOpensAndReports() async {
        let client = MockJellyfinClient()
        let model = makeModel(client)

        await model.start()
        await waitForStartReport(client)

        #expect(client.openLiveStreamRequests == ["ch4"])
        #expect(model.state == .playing)
        #expect(model.session?.playSessionId == "play1")
        #expect(client.startReports.map(\.itemId) == ["ch4"])
        #expect(client.startReports.first?.positionTicks == 0)
    }

    @Test("Stopping reports the channel stopped and stops the encode, once")
    func stopReleases() async {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()

        await model.stop()
        await model.stop()

        #expect(client.stopReports.map(\.itemId) == ["ch4"])
        #expect(client.stopEncodingCalls == ["play1"])
        // A reported session is released by its stopped report. Closing it
        // as well would drop the tuner for anyone sharing the stream.
        #expect(client.closedLiveStreams.isEmpty)
        #expect(model.session == nil)
    }

    @Test("A failed open shows the error and leaves nothing to release")
    func openFailure() async {
        let client = MockJellyfinClient()
        client.openLiveStreamResult = .failure(APIError.generic("tuner busy"))
        let model = makeModel(client)

        await model.start()
        #expect(model.state == .failed(APIError.generic("tuner busy").localizedDescription))

        await model.stop()
        #expect(client.stopReports.isEmpty)
        #expect(client.closedLiveStreams.isEmpty)
    }

    @Test("Backing out during the load closes the stream the server had already opened")
    func stopDuringOpenClosesStream() async {
        let client = MockJellyfinClient()
        let gate = AsyncGate()
        client.openLiveStreamGate = { _ in try? await gate.wait() }
        let model = makeModel(client)

        let start = Task { await model.start() }
        await gate.arrivals(atLeast: 1)
        await model.stop()
        await gate.open()
        await start.value

        #expect(client.closedLiveStreams.map(\.liveStreamId) == ["live1"])
        // Nothing was ever reported for it, so there is nothing to report stopped.
        #expect(client.startReports.isEmpty)
        #expect(client.stopReports.isEmpty)
        #expect(model.session == nil)
        #expect(model.state == .loading)
    }

    @Test("Switching channel releases the old stream under its own channel, then opens the new one")
    func switchChannel() async {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()

        await model.switchChannel(to: comfort)
        await waitForStartReport(client, count: 2)

        #expect(client.stopReports.map(\.itemId) == ["ch4"])
        #expect(client.stopEncodingCalls == ["play1"])
        #expect(client.openLiveStreamRequests == ["ch4", "ch5"])
        #expect(model.channel == comfort)
        #expect(model.session?.playSessionId == "play2")
        #expect(model.state == .playing)
        #expect(client.startReports.map(\.itemId) == ["ch4", "ch5"])
    }

    @Test("Picking the channel already playing does nothing")
    func switchToSameChannel() async {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()

        await model.switchChannel(to: trek)

        #expect(client.openLiveStreamRequests == ["ch4"])
        #expect(client.stopReports.isEmpty)
    }

    @Test("A player failure on the current stream fails the session; one from a stream already left is ignored")
    func playerFailure() async throws {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()
        let firstURL = try #require(model.session?.url)

        await model.switchChannel(to: comfort)
        model.playerFailed(url: firstURL, reason: "old stream closed")
        #expect(model.state == .playing)

        let currentURL = try #require(model.session?.url)
        model.playerFailed(url: currentURL, reason: "decode error")
        #expect(model.state == .failed("decode error"))
    }

    @Test("A player failure releases the stream at once, without waiting for Close")
    func playerFailureReleases() async throws {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()
        let url = try #require(model.session?.url)

        model.playerFailed(url: url, reason: "decode error")
        await waitForRelease(client)

        #expect(client.stopReports.map(\.itemId) == ["ch4"])
        #expect(client.stopEncodingCalls == ["play1"])
        #expect(model.session == nil)
        // Leaving the error screen afterwards has nothing left to release.
        await model.stop()
        #expect(client.stopReports.count == 1)
    }

    @Test("Leaving while Try Again is still releasing the old stream opens nothing new")
    func stopDuringRetry() async {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()
        let gate = AsyncGate()
        client.stopReportGate = { try? await gate.wait() }

        // Retry with a live session still held, so its release suspends.
        let retry = Task { await model.retry() }
        await gate.arrivals(atLeast: 1)
        await model.stop()
        await gate.open()
        await retry.value

        #expect(client.openLiveStreamRequests == ["ch4"])
        #expect(model.session == nil)
        #expect(client.stopReports.map(\.itemId) == ["ch4"])
    }

    @Test("Beginning twice starts one session")
    func beginIsOnce() async {
        let client = MockJellyfinClient()
        let model = makeModel(client)

        model.begin()
        model.begin()
        await waitForStartReport(client)

        #expect(client.openLiveStreamRequests == ["ch4"])
    }

    @Test("The open outlives the task that began it, so its stream can still be closed")
    func openSurvivesCallerCancellation() async {
        // A view's `.task` is cancelled when the view goes away. Were the
        // open to run inside it, the request would be cancelled mid-flight
        // and the stream the server had opened would never be closed.
        let client = MockJellyfinClient()
        let gate = AsyncGate()
        let cancelledAtGate = LockedFlag()
        client.openLiveStreamGate = { _ in
            try? await gate.wait()
            cancelledAtGate.set(Task.isCancelled)
        }
        let model = makeModel(client)

        let caller = Task {
            model.begin()
            try? await Task.sleep(for: .seconds(3600))
        }
        await gate.arrivals(atLeast: 1)
        caller.cancel()
        await model.stop()
        await gate.open()
        await client.recorded { !$0.closedLiveStreams.isEmpty }

        #expect(!cancelledAtGate.value)
        #expect(client.closedLiveStreams.map(\.liveStreamId) == ["live1"])
    }

    @Test("Try Again releases the failed stream and opens a fresh one")
    func retry() async throws {
        let client = MockJellyfinClient()
        let model = makeModel(client)
        await model.start()
        let url = try #require(model.session?.url)
        model.playerFailed(url: url, reason: "decode error")

        await model.retry()
        await waitForRelease(client)

        #expect(client.stopReports.map(\.itemId) == ["ch4"])
        #expect(client.openLiveStreamRequests == ["ch4", "ch4"])
        #expect(model.session?.playSessionId == "play2")
        #expect(model.state == .playing)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.withLock { flag }
    }

    func set(_ newValue: Bool) {
        lock.withLock { flag = newValue }
    }
}

@Suite("LiveGuideModel")
@MainActor
struct LiveGuideModelTests {
    /// A half-hour boundary. Tests add their own minutes past it.
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000 - 800_000_000.truncatingRemainder(dividingBy: 1800))
    private let trek = LiveChannel(id: "ch4", name: "Star Trek", number: "4")
    private let quiet = LiveChannel(id: "ch2", name: "Ashley TV", number: "2")

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) {
            self.now = now
        }
    }

    private func program(_ id: String, channel: String = "ch4", from: TimeInterval, to: TimeInterval) -> LiveProgram {
        LiveProgram(
            id: id,
            channelId: channel,
            name: id,
            startDate: Self.base.addingTimeInterval(from),
            endDate: Self.base.addingTimeInterval(to),
        )
    }

    private func makeModel(_ client: MockJellyfinClient, clock: Clock) -> LiveGuideModel {
        let model = LiveGuideModel(horizon: .seconds(7200), clock: { clock.now })
        model.attach(client: client)
        return model
    }

    @Test("The window opens on the current half hour and runs for the horizon")
    func windowIsHalfHourAligned() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .success([trek])
        let model = makeModel(client, clock: Clock(Self.base.addingTimeInterval(300)))

        await model.load()

        #expect(model.windowStart == Self.base)
        #expect(model.windowEnd == Self.base.addingTimeInterval(7200))
        let request = client.liveProgramsRequests.first
        #expect(request?.0 == ["ch4"])
        #expect(request?.1 == Self.base)
        #expect(request?.2 == Self.base.addingTimeInterval(7200))
        #expect(model.status == .loaded)
    }

    @Test("Now and next are read from the schedule, and a channel with no schedule has neither")
    func nowAndNext() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .success([quiet, trek])
        client.liveProgramsResult = .success([
            program("first", from: -600, to: 900),
            program("second", from: 900, to: 3600),
        ])
        let model = makeModel(client, clock: Clock(Self.base.addingTimeInterval(300)))

        await model.load()

        #expect(model.currentProgram(for: trek)?.id == "first")
        #expect(model.nextProgram(for: trek)?.id == "second")
        #expect(model.currentProgram(for: quiet) == nil)
        #expect(model.nextProgram(for: quiet) == nil)
    }

    @Test("A tick moves on-now to the next programme without refetching inside the half hour")
    func tickAdvancesNow() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .success([trek])
        client.liveProgramsResult = .success([
            program("first", from: -600, to: 900),
            program("second", from: 900, to: 3600),
        ])
        let clock = Clock(Self.base.addingTimeInterval(300))
        let model = makeModel(client, clock: clock)
        await model.load()

        clock.now = Self.base.addingTimeInterval(1000)
        await model.tick()

        #expect(model.currentProgram(for: trek)?.id == "second")
        #expect(client.liveChannelsRequestCount == 1)
    }

    @Test("Ticks past the half hour while a reload is under way do not start another")
    func tickDoesNotPileUpReloads() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .success([trek])
        let clock = Clock(Self.base.addingTimeInterval(300))
        let model = makeModel(client, clock: clock)
        await model.load()
        let gate = AsyncGate()
        client.liveChannelsGate = { try? await gate.wait() }

        clock.now = Self.base.addingTimeInterval(1860)
        let first = Task { await model.tick() }
        await gate.arrivals(atLeast: 1)
        await model.tick()
        await gate.open()
        await first.value

        #expect(client.liveChannelsRequestCount == 2)
        #expect(model.windowStart == Self.base.addingTimeInterval(1800))
    }

    @Test("A tick past the half hour reloads so the guide never opens in the past")
    func tickReloadsPastHalfHour() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .success([trek])
        let clock = Clock(Self.base.addingTimeInterval(300))
        let model = makeModel(client, clock: clock)
        await model.load()

        clock.now = Self.base.addingTimeInterval(1860)
        await model.tick()

        #expect(client.liveChannelsRequestCount == 2)
        #expect(model.windowStart == Self.base.addingTimeInterval(1800))
    }

    @Test("No channels is its own state, not an error")
    func emptyServer() async {
        let client = MockJellyfinClient()
        let model = makeModel(client, clock: Clock(Self.base))

        await model.load()

        #expect(model.status == .empty)
        #expect(!model.hasChannels)
        // The programme fetch still goes out, for no channels
        #expect(client.liveProgramsRequests.first?.0 == [])
    }

    @Test("A first load that fails reports it; a failed reload keeps the guide on screen")
    func failures() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .failure(APIError.generic("offline"))
        let clock = Clock(Self.base)
        let model = makeModel(client, clock: clock)

        await model.load()
        #expect(model.status == .failed(APIError.generic("offline").localizedDescription))

        client.liveChannelsResult = .success([trek])
        await model.load()
        #expect(model.status == .loaded)

        client.liveChannelsResult = .failure(APIError.generic("offline"))
        await model.load()
        #expect(model.status == .loaded)
        #expect(model.channels == [trek])
    }

    @Test("A retry after an empty or failed load picks up channels added since (#366)")
    func retryAfterEmptyOrFailed() async {
        let client = MockJellyfinClient()
        let model = makeModel(client, clock: Clock(Self.base))
        await model.load()
        #expect(model.status == .empty)

        client.liveChannelsResult = .failure(APIError.generic("offline"))
        await model.retryIfEmpty()
        #expect(model.status == .failed(APIError.generic("offline").localizedDescription))

        client.liveChannelsResult = .success([trek])
        await model.retryIfEmpty()
        #expect(model.status == .loaded)
        #expect(model.channels == [trek])
        #expect(client.liveChannelsRequestCount == 3)
    }

    @Test("A retry does nothing once there are channels, before the first load, or while one runs")
    func retryOnlyWhenEmpty() async {
        let client = MockJellyfinClient()
        client.liveChannelsResult = .success([trek])
        let model = makeModel(client, clock: Clock(Self.base))

        await model.retryIfEmpty()
        #expect(client.liveChannelsRequestCount == 0)

        await model.load()
        await model.retryIfEmpty()
        #expect(client.liveChannelsRequestCount == 1)

        client.liveChannelsResult = .success([])
        model.reset()
        model.attach(client: client)
        await model.load()
        let gate = AsyncGate()
        client.liveChannelsGate = { try? await gate.wait() }
        let first = Task { await model.retryIfEmpty() }
        await gate.arrivals(atLeast: 1)
        await model.retryIfEmpty()
        await gate.open()
        await first.value
        #expect(client.liveChannelsRequestCount == 3)
    }

    @Test("A retry keeps the empty verdict on screen until its answer lands")
    func retryIsQuiet() async {
        let client = MockJellyfinClient()
        let model = makeModel(client, clock: Clock(Self.base))
        await model.load()
        let gate = AsyncGate()
        client.liveChannelsGate = { try? await gate.wait() }

        let retry = Task { await model.retryIfEmpty() }
        await gate.arrivals(atLeast: 1)
        #expect(model.status == .empty)
        await gate.open()
        await retry.value
    }
}

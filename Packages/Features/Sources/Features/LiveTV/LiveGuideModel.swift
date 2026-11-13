import Foundation
import JellyfinKit
import Observation

/// Channels and their schedule for one stretch of time.
///
/// One type serves the guide grid, Home's On Air Now shelf and the player's
/// guide strip; they differ only in how far ahead they load. Nothing here is
/// cached to disk: a schedule goes stale by the minute, so a saved copy would
/// open on the wrong programme.
@Observable
@MainActor
final class LiveGuideModel {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        /// The server answered, with no channels
        case empty
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var channels: [LiveChannel] = []
    private(set) var programsByChannel: [String: [LiveProgram]] = [:]

    /// The guide grid's rows, built once per load. Building them means
    /// sorting and clipping every programme, which is too much to redo each
    /// time a view re-renders.
    private(set) var rows: [GuideRow] = []

    /// Bumped whenever `rows` is rebuilt, so the grid can tell cheaply
    /// whether it needs laying out again
    private(set) var rowsRevision = 0

    /// The loaded stretch of time. It opens on a half hour so the guide's
    /// time ruler starts on a round label.
    private(set) var windowStart: Date
    private(set) var windowEnd: Date

    /// The moment "on air" is judged against. Advanced by `tick()` rather
    /// than read live, so every view agrees on what is on.
    private(set) var now: Date

    private let horizon: TimeInterval
    private let clock: () -> Date
    private var client: (any JellyfinClientProtocol)?
    private var loadGeneration = 0
    private var loadsInFlight = 0

    /// - Parameters:
    ///   - horizon: How far past the opening half hour to load
    ///   - clock: The current time (injectable for tests)
    init(horizon: Duration = .seconds(12 * 3600), clock: @escaping () -> Date = Date.init) {
        self.horizon = TimeInterval(horizon.components.seconds)
        self.clock = clock
        let now = clock()
        self.now = now
        windowStart = Self.halfHourFloor(now)
        windowEnd = Self.halfHourFloor(now).addingTimeInterval(TimeInterval(horizon.components.seconds))
    }

    func attach(client: any JellyfinClientProtocol) {
        self.client = client
    }

    /// Forget everything, for a sign-out or a server without Live TV.
    func reset() {
        loadGeneration += 1
        client = nil
        channels = []
        programsByChannel = [:]
        rebuildRows()
        status = .idle
    }

    private func rebuildRows() {
        rows = channels.map { channel in
            GuideRow(channel: channel, cells: GuideLayout.cells(
                for: programs(for: channel),
                channelId: channel.id,
                windowStart: windowStart,
                windowEnd: windowEnd,
            ))
        }
        rowsRevision += 1
    }

    /// Whether the server has any channels to show. False until a load says so.
    var hasChannels: Bool {
        !channels.isEmpty
    }

    /// Load channels and the schedule from the current half hour.
    ///
    /// A reload keeps what is on screen until the new answer lands, and a
    /// failed reload keeps it altogether: a guide a few minutes old is more
    /// use than an error screen.
    func load() async {
        await load(reportsLoading: true)
    }

    /// Ask again after a load that found no channels or failed, so channels
    /// added on the server later still arrive. A guide with channels keeps
    /// itself current through `tick()`.
    ///
    /// Quiet: the status stays `.empty` or `.failed` until the answer lands,
    /// so a screen showing that verdict doesn't flash a loading state on
    /// every retry.
    func retryIfEmpty() async {
        guard client != nil, channels.isEmpty, loadsInFlight == 0 else { return }
        switch status {
        case .empty, .failed:
            await load(reportsLoading: false)
        case .idle, .loading, .loaded:
            return
        }
    }

    private func load(reportsLoading: Bool) async {
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        if channels.isEmpty, reportsLoading {
            status = .loading
        }

        let now = clock()
        let start = Self.halfHourFloor(now)
        let end = start.addingTimeInterval(horizon)
        do {
            let channels = try await client.getLiveChannels()
            let programs = try await client.getLivePrograms(channelIds: channels.map(\.id), from: start, to: end)
            guard generation == loadGeneration else { return }
            self.channels = channels
            programsByChannel = Dictionary(grouping: programs, by: \.channelId)
            windowStart = start
            windowEnd = end
            self.now = now
            rebuildRows()
            status = channels.isEmpty ? .empty : .loaded
        } catch {
            guard generation == loadGeneration else { return }
            if channels.isEmpty {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Move `now` forward, and reload once the opening half hour has passed
    /// so the guide never starts in the past.
    ///
    /// A reload already under way is left to finish. Several screens tick
    /// this model, and each new load supersedes the last, so on a slow
    /// server starting one per tick would mean none ever landed.
    func tick() async {
        let now = clock()
        self.now = now
        if Self.halfHourFloor(now) > windowStart, loadsInFlight == 0 {
            await load()
        }
    }

    func programs(for channel: LiveChannel) -> [LiveProgram] {
        programsByChannel[channel.id] ?? []
    }

    /// What the channel is showing now, if the guide knows
    func currentProgram(for channel: LiveChannel) -> LiveProgram? {
        programs(for: channel).first { $0.isAiring(at: now) }
    }

    /// The first programme starting after now
    func nextProgram(for channel: LiveChannel) -> LiveProgram? {
        programs(for: channel).first { $0.startDate > now }
    }

    /// The half hour at or before `date`
    static func halfHourFloor(_ date: Date) -> Date {
        let halfHour: TimeInterval = 1800
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / halfHour).rounded(.down) * halfHour)
    }
}

#if DEBUG
    extension LiveGuideModel {
        /// A loaded guide for previews: a scheduled channel, one of short
        /// items, and one the guide knows nothing about.
        static func preview() -> LiveGuideModel {
            let model = LiveGuideModel()
            let start = model.windowStart
            func program(_ channel: String, _ name: String, _ episode: String?, from: Double, minutes: Double) -> LiveProgram {
                LiveProgram(
                    id: "\(channel)-\(from)",
                    channelId: channel,
                    name: name,
                    episodeTitle: episode,
                    overview: "A preview programme, here so the guide's header has a description to lay out across more than one line.",
                    startDate: start.addingTimeInterval(from * 60),
                    endDate: start.addingTimeInterval((from + minutes) * 60),
                    genres: ["Science Fiction", "Adventure"],
                    officialRating: "TV-PG",
                    seasonNumber: 1,
                    episodeNumber: 26,
                )
            }
            model.channels = [
                LiveChannel(id: "2", name: "Ashley TV", number: "2"),
                LiveChannel(id: "3", name: "MTV", number: "3"),
                LiveChannel(id: "4", name: "Star Trek", number: "4"),
            ]
            model.programsByChannel = [
                "3": stride(from: -3.0, to: 720, by: 4).map { program("3", "Music Video", nil, from: $0, minutes: 4) },
                "4": stride(from: -27.0, to: 720, by: 50).map { program("4", "Star Trek", "Errand of Mercy", from: $0, minutes: 50) },
            ]
            model.rebuildRows()
            model.status = .loaded
            return model
        }
    }
#endif

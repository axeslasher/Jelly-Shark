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
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if channels.isEmpty {
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
    func tick() async {
        let now = clock()
        self.now = now
        if Self.halfHourFloor(now) > windowStart {
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

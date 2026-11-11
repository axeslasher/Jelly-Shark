import Foundation
import JellyfinKit

/// One focusable block on a channel's row of the guide: a programme, or a
/// stretch the guide has nothing for.
struct GuideCell: Identifiable, Hashable {
    let id: String
    let channelId: String
    /// Nil for a stretch with no programme information
    let program: LiveProgram?
    /// The part of the programme inside the guide's window; a programme
    /// already under way when the window opens is cut at the window's start
    let start: Date
    let end: Date

    /// Whether the programme began before the guide's left edge
    var startedEarlier: Bool {
        program.map { $0.startDate < start } ?? false
    }

    var minutes: Double {
        end.timeIntervalSince(start) / 60
    }
}

/// One channel's line of the guide
struct GuideRow: Identifiable, Hashable {
    let channel: LiveChannel
    let cells: [GuideCell]

    var id: String {
        channel.id
    }
}

/// The guide grid's arithmetic: which cells a row has, and how wide each is.
/// Pure, so the rules are tested without a screen.
enum GuideLayout {
    /// How much time fits across the screen
    static let visibleMinutes: Double = 120

    /// The guide's time scale: two hours across the grid's share of a
    /// 1920-point tvOS screen. A constant, not a measurement. The grid was
    /// first sized from its measured width, which changes on every frame of
    /// the sidebar's animation; each change re-laid out every cell and the
    /// main thread never caught up (seen on the simulator, 2026-11-11).
    static let pointsPerMinute: Double = 13

    /// The time ruler's spacing
    static let rulerStep: TimeInterval = 1800

    /// The longest single "no information" cell. An empty channel is cut
    /// into hours so moving sideways along it scrolls the guide in steps,
    /// like its neighbours, instead of in one twelve-hour leap.
    static let longestEmptyCell: TimeInterval = 3600

    /// Gaps shorter than this are schedule rounding, not missing data
    static let shortestEmptyCell: TimeInterval = 60

    /// A cell narrower than this shows no title; the header names it instead
    static let narrowestTitledCell: Double = 120

    /// A channel's row: its programmes clipped to the window, in order, with
    /// every unscheduled stretch filled so the row has no holes for focus to
    /// fall through.
    static func cells(
        for programs: [LiveProgram],
        channelId: String,
        windowStart: Date,
        windowEnd: Date,
    ) -> [GuideCell] {
        var cells: [GuideCell] = []
        var cursor = windowStart

        func fill(until end: Date) {
            while end.timeIntervalSince(cursor) >= shortestEmptyCell {
                // Cut on the clock hour, so empty cells line up down the grid
                let nextHour = Date(
                    timeIntervalSinceReferenceDate:
                    (cursor.timeIntervalSinceReferenceDate / longestEmptyCell).rounded(.down) * longestEmptyCell + longestEmptyCell,
                )
                let cellEnd = min(end, nextHour)
                cells.append(GuideCell(
                    id: "\(channelId)|none|\(Int(cursor.timeIntervalSinceReferenceDate))",
                    channelId: channelId,
                    program: nil,
                    start: cursor,
                    end: cellEnd,
                ))
                cursor = cellEnd
            }
        }

        for program in programs.sorted(by: { $0.startDate < $1.startDate }) {
            guard program.endDate > cursor, program.startDate < windowEnd else { continue }
            if program.startDate > cursor {
                fill(until: min(program.startDate, windowEnd))
            }
            // `max` also trims a programme the guide lists as overlapping
            // the one before it.
            let start = max(program.startDate, cursor)
            let end = min(program.endDate, windowEnd)
            guard end > start else { continue }
            cells.append(GuideCell(id: "\(channelId)|\(program.id)", channelId: channelId, program: program, start: start, end: end))
            cursor = end
        }
        fill(until: windowEnd)
        return cells
    }

    /// Width of a cell's block. The gap to the next cell comes out of the
    /// cell's own span, so every row stays aligned to the ruler however many
    /// cells it has.
    static func width(of cell: GuideCell, pointsPerMinute: Double, gap: Double) -> Double {
        max(cell.minutes * pointsPerMinute - gap, 1)
    }

    static func showsTitle(width: Double) -> Bool {
        width >= narrowestTitledCell
    }

    /// Distance from the guide's left edge to `date`
    static func offset(of date: Date, windowStart: Date, pointsPerMinute: Double) -> Double {
        date.timeIntervalSince(windowStart) / 60 * pointsPerMinute
    }

    /// The times labelled on the ruler: every half hour of the window
    static func rulerMarks(windowStart: Date, windowEnd: Date) -> [Date] {
        Array(stride(
            from: windowStart.timeIntervalSinceReferenceDate,
            to: windowEnd.timeIntervalSinceReferenceDate,
            by: rulerStep,
        )).map(Date.init(timeIntervalSinceReferenceDate:))
    }
}

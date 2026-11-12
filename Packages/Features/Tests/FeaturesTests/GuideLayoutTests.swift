@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("GuideLayout")
struct GuideLayoutTests {
    /// On a clock hour, so the hour-aligned cuts are easy to read
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000 - 800_000_000.truncatingRemainder(dividingBy: 3600))
    private var end: Date {
        start.addingTimeInterval(4 * 3600)
    }

    private func program(_ id: String, from: Double, to: Double) -> LiveProgram {
        LiveProgram(
            id: id,
            channelId: "c",
            name: id,
            startDate: start.addingTimeInterval(from * 60),
            endDate: start.addingTimeInterval(to * 60),
        )
    }

    private func cells(_ programs: [LiveProgram]) -> [GuideCell] {
        GuideLayout.cells(for: programs, channelId: "c", windowStart: start, windowEnd: end)
    }

    /// Minutes from the window start, as (start, end, programme id or nil)
    private func spans(_ cells: [GuideCell]) -> [[Double]] {
        cells.map { [$0.start.timeIntervalSince(start) / 60, $0.end.timeIntervalSince(start) / 60] }
    }

    @Test("A programme already under way is cut at the window's start and says so")
    func clipsAtWindowStart() {
        let row = cells([program("a", from: -27, to: 23), program("b", from: 23, to: 240)])
        #expect(spans(row) == [[0, 23], [23, 240]])
        #expect(row[0].startedEarlier)
        #expect(!row[1].startedEarlier)
    }

    @Test("A programme running past the window is cut at its end")
    func clipsAtWindowEnd() {
        let row = cells([program("a", from: 0, to: 200), program("b", from: 200, to: 400)])
        #expect(spans(row) == [[0, 200], [200, 240]])
    }

    @Test("Every row covers the whole window with no holes or overlaps")
    func rowsAreContiguous() {
        let row = cells([program("a", from: 10, to: 40), program("b", from: 95, to: 130)])
        #expect(row.first?.start == start)
        #expect(row.last?.end == end)
        for (cell, next) in zip(row, row.dropFirst()) {
            #expect(cell.end == next.start)
        }
    }

    @Test("A gap becomes no-information cells cut on the clock hour")
    func fillsGaps() {
        let row = cells([program("a", from: 10, to: 40), program("b", from: 130, to: 240)])
        #expect(spans(row) == [[0, 10], [10, 40], [40, 60], [60, 120], [120, 130], [130, 240]])
        #expect(row.map { $0.program?.id } == [nil, "a", nil, nil, nil, "b"])
    }

    @Test("A channel with no schedule is one no-information cell per hour")
    func emptyChannel() {
        let row = cells([])
        #expect(spans(row) == [[0, 60], [60, 120], [120, 180], [180, 240]])
        #expect(row.allSatisfy { $0.program == nil })
        #expect(Set(row.map(\.id)).count == row.count)
    }

    @Test("A sub-minute gap between programmes is not shown as missing data")
    func ignoresRoundingGaps() {
        let row = cells([program("a", from: 0, to: 30), program("b", from: 30.5, to: 240)])
        #expect(row.map { $0.program?.id } == ["a", "b"])
    }

    @Test("A sub-minute gap leaves no hole: the next programme starts where the last one ended")
    func roundingGapsLeaveNoHole() {
        let row = cells([
            program("a", from: 0, to: 30),
            program("b", from: 30.5, to: 60),
            program("c", from: 60.5, to: 240),
        ])
        #expect(spans(row) == [[0, 30], [30, 60], [60, 240]])
    }

    @Test("A cell a reload removed is replaced by its channel's first cell; one still there is not")
    func focusReplacement() {
        let rows = [GuideRow(channel: LiveChannel(id: "c", name: "C"), cells: cells([program("b", from: 0, to: 240)]))]
        #expect(LiveGuideView.replacement(for: "c|gone", in: rows) == "c|b")
        #expect(LiveGuideView.replacement(for: "c|b", in: rows) == nil)
        #expect(LiveGuideView.replacement(for: "other|gone", in: rows) == nil)
    }

    @Test("Programmes outside the window, or listed out of order or overlapping, do not break the row")
    func tolerantOfMessyGuides() {
        let row = cells([
            program("late", from: 300, to: 360),
            program("b", from: 50, to: 240),
            program("early", from: -120, to: -60),
            program("a", from: 0, to: 60),
        ])
        #expect(row.map { $0.program?.id } == ["a", "b"])
        #expect(spans(row) == [[0, 60], [60, 240]])
    }

    @Test("Widths keep every row aligned to the ruler whatever its cell count")
    func widthsAlign() {
        let pointsPerMinute = 10.0
        let gap = 8.0
        let many = cells(stride(from: 0.0, to: 240, by: 4).map { program("m\($0)", from: $0, to: $0 + 4) })
        let one = cells([program("a", from: 0, to: 240)])
        func rowWidth(_ row: [GuideCell]) -> Double {
            row.reduce(0) { $0 + GuideLayout.width(of: $1, pointsPerMinute: pointsPerMinute, gap: gap) + gap }
        }
        #expect(rowWidth(many) == 2400)
        #expect(rowWidth(one) == 2400)
        // A four-minute item is too narrow for a title; a half hour is not.
        #expect(!GuideLayout.showsTitle(width: GuideLayout.width(of: many[0], pointsPerMinute: pointsPerMinute, gap: gap)))
        #expect(GuideLayout.showsTitle(width: 30 * pointsPerMinute - gap))
    }

    @Test("The ruler marks every half hour of the window")
    func rulerMarks() {
        let marks = GuideLayout.rulerMarks(windowStart: start, windowEnd: end)
        #expect(marks.count == 8)
        #expect(marks.first == start)
        #expect(marks.last == end.addingTimeInterval(-1800))
        #expect(GuideLayout.offset(of: start.addingTimeInterval(300), windowStart: start, pointsPerMinute: 10) == 50)
    }
}

@Suite("Live TV artwork and titles")
struct LiveTVPresentationTests {
    private let channel = LiveChannel(id: "ch4", name: "Star Trek", number: "4", imageTag: "logo")
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func program(primary: String? = nil, thumb: String? = nil, backdrop: String? = nil) -> LiveProgram {
        LiveProgram(
            id: "p1",
            channelId: "ch4",
            name: "Star Trek: Voyager",
            episodeTitle: "Ex Post Facto",
            startDate: start,
            endDate: start.addingTimeInterval(60),
            seasonNumber: 1,
            episodeNumber: 8,
            imageTag: primary,
            thumbImageTag: thumb,
            backdropImageTag: backdrop,
        )
    }

    private func artworkPath(_ program: LiveProgram?, channel: LiveChannel? = nil) -> String? {
        MockJellyfinClient().liveArtworkURL(channel: channel ?? self.channel, program: program, maxWidth: 1000)?.path()
    }

    @Test("A landscape still beats the poster, and a thumb beats a backdrop")
    func prefersLandscape() {
        #expect(artworkPath(program(primary: "p", thumb: "t", backdrop: "b")) == "/Items/p1/Images/Thumb")
        #expect(artworkPath(program(primary: "p", backdrop: "b")) == "/Items/p1/Images/Backdrop")
    }

    @Test("With only a poster, the poster is used")
    func fallsBackToPoster() {
        #expect(artworkPath(program(primary: "p")) == "/Items/p1/Images/Primary")
    }

    @Test("With no programme art, or no programme, the channel logo is used")
    func fallsBackToChannelLogo() {
        #expect(artworkPath(program()) == "/Items/ch4/Images/Primary")
        #expect(artworkPath(nil) == "/Items/ch4/Images/Primary")
    }

    @Test("With nothing at all there is no artwork")
    func noArtwork() {
        #expect(artworkPath(nil, channel: LiveChannel(id: "x", name: "Bare")) == nil)
    }

    @Test("For an episode the player leads with the episode title, as the library player does")
    func nowPlayingEpisode() {
        let item = LiveTVText.nowPlayingItem(channel: channel, program: program())
        #expect(item.name == "Ex Post Facto")
        // No "LIVE" in the text: the system player draws its own badge.
        #expect(item.tagline == "Star Trek: Voyager · S1E8 · 4 Star Trek")
        #expect(item.id == "ch4")
    }

    @Test("A programme with no episode title leads with its own name")
    func nowPlayingProgramme() {
        let film = LiveProgram(id: "m", channelId: "ch4", name: "Weapons", startDate: start, endDate: start.addingTimeInterval(60))
        let item = LiveTVText.nowPlayingItem(channel: channel, program: film)
        #expect(item.name == "Weapons")
        #expect(item.tagline == "4 Star Trek")
    }

    @Test("With no programme the player still has both lines its title view needs")
    func nowPlayingChannelOnly() {
        let item = LiveTVText.nowPlayingItem(channel: channel, program: nil)
        #expect(item.name == "Star Trek")
        #expect(item.tagline == "No program information")
    }
}

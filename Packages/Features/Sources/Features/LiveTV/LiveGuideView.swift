import DesignSystem
import JellyfinKit
import SwiftUI

/// The Live TV guide: channels down the side, time across the top, and a
/// header describing whichever programme has focus. Selecting a cell plays
/// its channel.
///
/// Focus (tvOS):
/// - Focusable: every cell in the grid, including "no information" cells.
/// - Not focusable: the channel column, the time ruler and the header.
/// - Default focus: the first channel's cell at the left edge, which is what
///   that channel is showing now.
/// - Left from a row's first cell leaves for the sidebar.
///
/// Movement is the system's own: the grid is ordinary buttons in ordinary
/// scroll views, so up and down land on the nearest cell by position, which
/// is what keeps the viewer's place in time. How that feels is only
/// checkable on a device.
struct LiveGuideView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(PlaybackPreferences.self) private var playbackPreferences

    let guide: LiveGuideModel

    @FocusState private var focusedCell: String?

    /// The cell the header describes. Trails `focusedCell` but is never
    /// cleared, so the header keeps its content while focus is in the sidebar.
    @State private var describedCell: String?

    /// How far the grid has scrolled sideways, which the ruler follows
    @State private var scrollOffset: CGFloat = 0
    @State private var viewWidth: CGFloat = 1920
    @State private var playingChannel: LiveChannel?

    private static let channelColumnWidth: CGFloat = 190
    private static let rowHeight: CGFloat = 84
    private static let gap = SpacingTokens.xs
    private static let leadingPadding = SpacingTokens.xl

    private struct Row: Identifiable {
        let channel: LiveChannel
        let cells: [GuideCell]
        var id: String {
            channel.id
        }
    }

    var body: some View {
        Group {
            switch guide.status {
            case .idle, .loading:
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                message(Text("liveTV.guide.noChannels", bundle: #bundle, comment: "Shown on the live TV guide when the server has no channels."))
            case .failed:
                FailedShelfNotice(retry: { Task { await guide.load() } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                loaded
            }
        }
        .background(theme.background)
        .task {
            // The schedule moves under a guide left open: keep "now" current
            // and let the model reload when the half hour turns.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await guide.tick()
            }
        }
        .fullScreenCover(item: $playingChannel) { channel in
            if let client = session.client {
                LivePlaybackView(
                    client: client,
                    channel: channel,
                    guide: guide,
                    streamingBitrateCap: playbackPreferences.streamingQuality.bitsPerSecond,
                )
            }
        }
    }

    private func message(_ text: Text) -> some View {
        text
            .jsStyle(.headline)
            .foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loaded

    private var rows: [Row] {
        guide.channels.map { channel in
            Row(channel: channel, cells: GuideLayout.cells(
                for: guide.programs(for: channel),
                channelId: channel.id,
                windowStart: guide.windowStart,
                windowEnd: guide.windowEnd,
            ))
        }
    }

    private var pointsPerMinute: Double {
        let laneWidth = viewWidth - Self.leadingPadding - Self.channelColumnWidth - Self.gap
        return GuideLayout.pointsPerMinute(laneWidth: laneWidth)
    }

    private var loaded: some View {
        let rows = rows
        let pointsPerMinute = pointsPerMinute
        let described = describedCell.flatMap { id in rows.lazy.flatMap(\.cells).first { $0.id == id } }
            ?? rows.first?.cells.first

        return VStack(alignment: .leading, spacing: SpacingTokens.md) {
            if let described, let channel = guide.channels.first(where: { $0.id == described.channelId }) {
                GuideHeader(cell: described, channel: channel, now: guide.now, client: session.client)
                    .padding(.leading, Self.leadingPadding)
                    .padding(.trailing, SpacingTokens.xxl)
            }

            ruler(pointsPerMinute: pointsPerMinute)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: Self.gap) {
                    // Plain stacks, not lazy ones: a lazy stack drops rows
                    // that scroll away, and focus moving toward a row that
                    // is not there leaves the grid for the sidebar instead.
                    VStack(spacing: Self.gap) {
                        ForEach(rows) { row in
                            channelLabel(row.channel)
                        }
                    }

                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: Self.gap) {
                            ForEach(rows) { row in
                                HStack(spacing: Self.gap) {
                                    ForEach(row.cells) { cell in
                                        cellButton(cell, channel: row.channel, pointsPerMinute: pointsPerMinute)
                                    }
                                }
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            nowLine(pointsPerMinute: pointsPerMinute)
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.x
                    } action: { _, offset in
                        scrollOffset = offset
                    }
                }
                .padding(.leading, Self.leadingPadding)
                .padding(.bottom, SpacingTokens.xl)
            }
        }
        .padding(.top, SpacingTokens.lg)
        .defaultFocus($focusedCell, rows.first?.cells.first?.id)
        .onChange(of: focusedCell) { _, focused in
            if let focused {
                describedCell = focused
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            viewWidth = width
        }
    }

    private func channelLabel(_ channel: LiveChannel) -> some View {
        HStack(spacing: SpacingTokens.xs) {
            if let number = channel.number {
                Text(number)
                    .foregroundStyle(theme.tertiary)
                    .monospacedDigit()
            }
            Text(channel.name)
                .foregroundStyle(theme.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .jsStyle(.caption, .emphasized)
        .padding(.horizontal, SpacingTokens.xs)
        .frame(width: Self.channelColumnWidth, height: Self.rowHeight, alignment: .leading)
        .background(theme.surfaceElevated, in: .rect(cornerRadius: theme.cornerRadius))
        .accessibilityElement(children: .combine)
    }

    private func cellButton(_ cell: GuideCell, channel: LiveChannel, pointsPerMinute: Double) -> some View {
        let width = GuideLayout.width(of: cell, pointsPerMinute: pointsPerMinute, gap: Self.gap)
        return Button {
            playingChannel = channel
        } label: {
            HStack(spacing: SpacingTokens.xs) {
                if GuideLayout.showsTitle(width: width) {
                    if cell.startedEarlier {
                        Image(systemName: "chevron.left")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    Text(cell.program?.name ?? String(localized: LiveTVText.noProgramInfo))
                        .lineLimit(1)
                }
            }
            .jsStyle(.body, .emphasized)
            .padding(.horizontal, GuideLayout.showsTitle(width: width) ? SpacingTokens.sm : 0)
            .frame(width: width, height: Self.rowHeight, alignment: .leading)
        }
        .buttonStyle(GuideCellButtonStyle(isEmpty: cell.program == nil))
        .focused($focusedCell, equals: cell.id)
        // A narrow cell shows no title, so VoiceOver gets it here.
        .accessibilityLabel(GuideHeader.accessibilityLabel(for: cell, channel: channel))
    }

    /// The time ruler. It sits outside the grid's scroll view so it stays
    /// put when the rows scroll up, and follows the sideways scroll by offset.
    private func ruler(pointsPerMinute: Double) -> some View {
        let step = GuideLayout.rulerStep / 60 * pointsPerMinute
        return HStack(spacing: 0) {
            ForEach(GuideLayout.rulerMarks(windowStart: guide.windowStart, windowEnd: guide.windowEnd), id: \.self) { mark in
                Text(LiveTVText.time(mark))
                    .jsStyle(.caption, .emphasized)
                    .foregroundStyle(theme.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: step, alignment: .leading)
            }
        }
        .offset(x: -scrollOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.leading, Self.leadingPadding + Self.channelColumnWidth + Self.gap)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func nowLine(pointsPerMinute: Double) -> some View {
        if guide.now >= guide.windowStart, guide.now < guide.windowEnd {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .offset(x: GuideLayout.offset(of: guide.now, windowStart: guide.windowStart, pointsPerMinute: pointsPerMinute))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A guide cell: a flat block at rest, filled with the theme's focus colour
/// when focused. No lift or scale, because cells sit edge to edge and a
/// grown cell would cover its neighbours' titles.
private struct GuideCellButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let isEmpty: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? theme.onFocusFill : (isEmpty ? theme.tertiary : theme.secondary))
            .background {
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(theme.surface)
                    .overlay {
                        if isFocused {
                            RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .fill(theme.focusFill ?? theme.primary)
                        }
                    }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(theme.animation, value: isFocused)
    }
}

/// What the focused cell is: when, on which channel, how far through, and
/// the programme's details.
private struct GuideHeader: View {
    @Environment(\.theme) private var theme

    let cell: GuideCell
    let channel: LiveChannel
    let now: Date
    let client: (any JellyfinClientProtocol)?

    private static let artworkWidth: CGFloat = 480
    private static let height: CGFloat = 300

    var body: some View {
        HStack(alignment: .top, spacing: SpacingTokens.xl) {
            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                Text(Self.whenAndWhere(cell, channel: channel))
                    .jsStyle(.caption)
                    .foregroundStyle(theme.secondary)
                    .monospacedDigit()

                Text(cell.program?.name ?? channel.name)
                    .jsStyle(.display)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let program = cell.program, program.isAiring(at: now) {
                    progress(program)
                }

                if let line = Self.episodeLine(cell) {
                    Text(line)
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }

                if let overview = cell.program?.overview, !overview.isEmpty {
                    Text(overview)
                        .jsStyle(.body)
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(3)
                }

                if let genres = cell.program?.genres, !genres.isEmpty {
                    Text(genres.prefix(4).joined(separator: " · "))
                        .jsStyle(.caption)
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ArtworkImage(
                url: client?.liveArtworkURL(channel: channel, program: cell.program, maxWidth: 1000),
                placeholderIcon: "antenna.radiowaves.left.and.right",
                cornerRadius: theme.cornerRadiusLarge,
            )
            .frame(width: Self.artworkWidth, height: Self.artworkWidth * 9 / 16)
        }
        // Fixed, so the grid below does not jump as focus moves between a
        // programme with a long overview and one with none.
        .frame(height: Self.height, alignment: .top)
        .accessibilityHidden(true)
    }

    private func progress(_ program: LiveProgram) -> some View {
        let minutesLeft = max(Int((program.endDate.timeIntervalSince(now) / 60).rounded(.up)), 0)
        return HStack(spacing: SpacingTokens.sm) {
            Capsule()
                .fill(theme.surfaceElevated)
                .frame(width: 220, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: 220 * program.progress(at: now), height: 6)
                }
            Text("liveTV.guide.minutesLeft \(minutesLeft)", bundle: #bundle, comment: "How many minutes remain of the live TV programme that has focus.")
                .jsStyle(.caption, .emphasized)
                .foregroundStyle(theme.accent)
                .monospacedDigit()
        }
    }

    /// "1:33 – 2:23 PM · 4 Star Trek". A programme cut at the guide's left
    /// edge still shows when it really began.
    static func whenAndWhere(_ cell: GuideCell, channel: LiveChannel) -> String {
        let start = cell.program?.startDate ?? cell.start
        let end = cell.program?.endDate ?? cell.end
        return "\(LiveTVText.time(start)) – \(LiveTVText.time(end)) · \(LiveTVText.channelLabel(channel))"
    }

    /// "S1 E26 · Errand of Mercy · TV-PG"
    static func episodeLine(_ cell: GuideCell) -> String? {
        guard let program = cell.program else {
            return String(localized: LiveTVText.noProgramInfo)
        }
        let parts = [LiveTVText.episodeCode(program), program.episodeTitle, program.officialRating]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(for cell: GuideCell, channel: LiveChannel) -> String {
        let title = cell.program?.name ?? String(localized: LiveTVText.noProgramInfo)
        return "\(title), \(whenAndWhere(cell, channel: channel))"
    }
}

#if DEBUG
    private struct LiveGuidePreview: View {
        var body: some View {
            LiveGuideView(guide: .preview())
        }
    }

    #Preview("Standard", traits: .featuresEnvironment(theme: .standard)) { LiveGuidePreview() }
    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) { LiveGuidePreview() }
    #Preview("Action", traits: .featuresEnvironment(theme: .action)) { LiveGuidePreview() }
    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) { LiveGuidePreview() }
    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) { LiveGuidePreview() }
#endif

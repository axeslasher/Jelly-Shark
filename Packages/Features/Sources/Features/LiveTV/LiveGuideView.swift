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

    @State private var playingChannel: LiveChannel?

    /// How far the grid has scrolled sideways. A reference the ruler reads,
    /// so scrolling re-renders the ruler alone and never the grid.
    @State private var scroll = GuideScroll()

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

    private var loaded: some View {
        let rows = guide.rows
        let described = describedCell.flatMap { id in rows.lazy.flatMap(\.cells).first { $0.id == id } }
            ?? rows.first?.cells.first

        return VStack(alignment: .leading, spacing: SpacingTokens.md) {
            if let described, let channel = guide.channels.first(where: { $0.id == described.channelId }) {
                GuideHeader(cell: described, channel: channel, now: guide.now, client: session.client)
                    .padding(.leading, GuideMetrics.leadingPadding)
                    .padding(.trailing, SpacingTokens.screenPadding)
            }

            GuideRuler(windowStart: guide.windowStart, windowEnd: guide.windowEnd, scroll: scroll)

            GuideGrid(
                rows: rows,
                revision: guide.rowsRevision,
                windowStart: guide.windowStart,
                windowEnd: guide.windowEnd,
                now: guide.now,
                scroll: scroll,
                focusedCell: $focusedCell,
                onSelect: { playingChannel = $0 },
            )
            // The header changes on every focus move; without this the
            // whole grid would be re-laid out each time it did.
            .equatable()
        }
        .padding(.top, SpacingTokens.lg)
        .defaultFocus($focusedCell, rows.first?.cells.first?.id)
        .onChange(of: focusedCell) { _, focused in
            if let focused {
                describedCell = focused
            }
        }
    }
}

private enum GuideMetrics {
    static let channelColumnWidth: CGFloat = 190
    static let rowHeight: CGFloat = 84
    static let rulerHeight: CGFloat = 32
    static let gap = SpacingTokens.xs
    /// The margin Home and the library screens keep
    static let leadingPadding = SpacingTokens.screenPadding
    static let edgeFadeLength = SpacingTokens.xxl
}

@Observable
@MainActor
private final class GuideScroll {
    var offset: CGFloat = 0
    var verticalOffset: CGFloat = 0
}

/// Softens an edge that guide content scrolls under: the leading edge,
/// where programmes pass beneath the channel column, or the top, where rows
/// pass beneath the time ruler. Opaque while the guide rests at its start,
/// so the first cells are not dimmed. A view of its own, so scrolling
/// redraws the mask and never the grid.
private struct GuideEdgeFade: View {
    enum Edge {
        case leading, top
    }

    let scroll: GuideScroll
    let edge: Edge

    var body: some View {
        let offset = edge == .leading ? scroll.offset : scroll.verticalOffset
        let hidden = min(max(offset, 0) / GuideMetrics.edgeFadeLength, 1)
        let colors: [Color] = [.black.opacity(1 - hidden), .black]
        switch edge {
        case .leading:
            HStack(spacing: 0) {
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    .frame(width: GuideMetrics.edgeFadeLength)
                Color.black
            }
        case .top:
            VStack(spacing: 0) {
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                    .frame(height: GuideMetrics.edgeFadeLength)
                Color.black
            }
        }
    }
}

/// The time ruler. It sits outside the grid's scroll view so it stays put
/// when the rows scroll up, and follows the sideways scroll by offset.
private struct GuideRuler: View {
    @Environment(\.theme) private var theme

    let windowStart: Date
    let windowEnd: Date
    let scroll: GuideScroll

    var body: some View {
        let step = GuideLayout.rulerStep / 60 * GuideLayout.pointsPerMinute
        // The marks ride in an overlay so their combined width, which is the
        // whole twelve hours, never reaches layout. Laid out in line, they
        // made this screen twelve hours wide and centred it on the middle.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: GuideMetrics.rulerHeight)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(GuideLayout.rulerMarks(windowStart: windowStart, windowEnd: windowEnd), id: \.self) { mark in
                        Text(LiveTVText.time(mark))
                            .jsStyle(.caption, .emphasized)
                            .foregroundStyle(theme.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: step, alignment: .leading)
                    }
                }
                .fixedSize()
                .offset(x: -scroll.offset)
            }
            .clipped()
            .mask { GuideEdgeFade(scroll: scroll, edge: .leading) }
            .padding(.leading, GuideMetrics.leadingPadding + GuideMetrics.channelColumnWidth + GuideMetrics.gap)
            .accessibilityHidden(true)
    }
}

/// The channel column and the scrolling block of programme cells.
private struct GuideGrid: View, Equatable {
    @Environment(\.theme) private var theme

    let rows: [GuideRow]
    let revision: Int
    let windowStart: Date
    let windowEnd: Date
    let now: Date
    let scroll: GuideScroll
    let focusedCell: FocusState<String?>.Binding
    let onSelect: (LiveChannel) -> Void

    /// `revision` stands in for `rows`, and `now` only moves the now-line.
    /// The binding and the closure are the same on every pass.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.now == rhs.now
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: GuideMetrics.gap) {
                // Plain stacks, not lazy ones: a lazy stack drops rows that
                // scroll away, and focus moving toward a row that is not
                // there leaves the grid for the sidebar instead.
                VStack(spacing: GuideMetrics.gap) {
                    ForEach(rows) { row in
                        channelLabel(row.channel)
                    }
                }

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: GuideMetrics.gap) {
                        ForEach(rows) { row in
                            HStack(spacing: GuideMetrics.gap) {
                                ForEach(row.cells) { cell in
                                    cellButton(cell, channel: row.channel)
                                }
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        nowLine
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.x
                } action: { _, offset in
                    scroll.offset = offset
                }
                // A mask draws only: every cell stays focusable under it.
                .mask { GuideEdgeFade(scroll: scroll, edge: .leading) }
            }
            .padding(.leading, GuideMetrics.leadingPadding)
            .padding(.bottom, SpacingTokens.xl)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scroll.verticalOffset = offset
        }
        .mask { GuideEdgeFade(scroll: scroll, edge: .top) }
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
        .frame(width: GuideMetrics.channelColumnWidth, height: GuideMetrics.rowHeight, alignment: .leading)
        .background(theme.surfaceElevated, in: .rect(cornerRadius: theme.cornerRadius))
        .accessibilityElement(children: .combine)
    }

    private func cellButton(_ cell: GuideCell, channel: LiveChannel) -> some View {
        let width = GuideLayout.width(of: cell, pointsPerMinute: GuideLayout.pointsPerMinute, gap: GuideMetrics.gap)
        let showsTitle = GuideLayout.showsTitle(width: width)
        return Button {
            onSelect(channel)
        } label: {
            HStack(spacing: SpacingTokens.xs) {
                if showsTitle {
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
            .padding(.horizontal, showsTitle ? SpacingTokens.sm : 0)
            .frame(width: width, height: GuideMetrics.rowHeight, alignment: .leading)
        }
        .buttonStyle(GuideCellButtonStyle(isEmpty: cell.program == nil))
        .focused(focusedCell, equals: cell.id)
        // A narrow cell shows no title, so VoiceOver gets it here.
        .accessibilityLabel(GuideHeader.accessibilityLabel(for: cell, channel: channel))
    }

    @ViewBuilder
    private var nowLine: some View {
        if now >= windowStart, now < windowEnd {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .offset(x: GuideLayout.offset(of: now, windowStart: windowStart, pointsPerMinute: GuideLayout.pointsPerMinute))
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

/// What the focused cell is: the programme's details, and how far through
/// it is when it is on now.
private struct GuideHeader: View {
    @Environment(\.theme) private var theme

    let cell: GuideCell
    let channel: LiveChannel
    let now: Date
    let client: (any JellyfinClientProtocol)?

    private static let artworkWidth: CGFloat = 480
    /// Room for the lockup with a three-line overview
    private static let height: CGFloat = 340

    var body: some View {
        HStack(alignment: .top, spacing: SpacingTokens.xl) {
            // The Home hero's lockup, in its order, tokens and spacing: the
            // title, then the fact row, episode and overview as one tighter
            // block, then one subdued line. When and where are left to the
            // grid, which the focused cell already shows them on.
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                Text(cell.program?.name ?? channel.name)
                    .jsStyle(.display)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    // Always full size. It was allowed to shrink to fit, and
                    // in this fixed-height header that let the same title
                    // render at different sizes from one programme to the
                    // next (seen on device, 2026-11-11). A title too long for
                    // the line is cut with an ellipsis; when the header runs
                    // out of height, the overview gives up lines first.
                    .layoutPriority(1)

                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    // The detail page's fact row: year, length, certificate.
                    MediaMetadataRow(
                        yearText: cell.program?.productionYear.map { String($0) },
                        runtime: cell.program?.formattedRuntime,
                        seasons: nil,
                        seasonsIcon: "tv",
                        communityRating: nil,
                        criticRating: nil,
                        certificate: cell.program?.officialRating,
                        resolution: nil,
                        videoRange: nil,
                        audioFormat: nil,
                    )
                    if let line = Self.episodeLine(cell) {
                        Text(line)
                            .jsStyle(.headline)
                            .foregroundStyle(theme.primary)
                            .lineLimit(1)
                    }
                    if let overview = cell.program?.overview, !overview.isEmpty {
                        Text(overview)
                            .jsStyle(.overview)
                            .foregroundStyle(theme.primary)
                            .lineLimit(3)
                    }
                }

                if let genres = cell.program?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .jsStyle(.caption, .emphasized)
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
            .overlay(alignment: .bottom) {
                if let program = cell.program, program.isAiring(at: now) {
                    progress(program)
                }
            }
            .clipShape(.rect(cornerRadius: theme.cornerRadiusLarge))
        }
        // Fixed, so the grid below does not jump as focus moves between a
        // programme with a long overview and one with none.
        .frame(height: Self.height, alignment: .top)
        .accessibilityHidden(true)
    }

    /// How far through the programme is, banding the foot of the artwork the
    /// way Home's Continue Watching cards show progress.
    private func progress(_ program: LiveProgram) -> some View {
        let minutesLeft = max(Int((program.endDate.timeIntervalSince(now) / 60).rounded(.up)), 0)
        return HStack(spacing: SpacingTokens.xs) {
            Capsule()
                .fill(theme.background.opacity(0.9))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: geometry.size.width * program.progress(at: now))
                    }
                }
            Text("liveTV.guide.minutesLeft \(minutesLeft)", bundle: #bundle, comment: "How many minutes remain of the live TV programme that has focus.")
                .monospacedDigit()
                .fixedSize()
        }
        .jsStyle(.body, .subtle)
        .foregroundStyle(theme.primary.opacity(0.9))
        .padding(SpacingTokens.sm)
        .background {
            LinearGradient(
                colors: [theme.background.opacity(0.55), .clear],
                startPoint: .bottom,
                endPoint: .top,
            )
        }
    }

    /// "1:33 – 2:23 PM · 4 Star Trek", for VoiceOver. A programme cut at the
    /// guide's left edge still gives when it really began.
    static func whenAndWhere(_ cell: GuideCell, channel: LiveChannel) -> String {
        let start = cell.program?.startDate ?? cell.start
        let end = cell.program?.endDate ?? cell.end
        return "\(LiveTVText.time(start)) – \(LiveTVText.time(end)) · \(LiveTVText.channelLabel(channel))"
    }

    /// "S1E26 · Errand of Mercy". The rating is drawn beside it as a badge.
    static func episodeLine(_ cell: GuideCell) -> String? {
        guard let program = cell.program else {
            return String(localized: LiveTVText.noProgramInfo)
        }
        let parts = [LiveTVText.episodeCode(program), program.episodeTitle]
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

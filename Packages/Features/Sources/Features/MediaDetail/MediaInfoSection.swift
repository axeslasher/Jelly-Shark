import DesignSystem
import JellyfinKit
import SwiftUI

/// Deep-cut facts for the uber nerds, below the shelves: three columns —
/// Information (studio, release, status, genres), Languages (original audio,
/// audio tracks, subtitles), and File (name over a two-column grid of size,
/// container, codec, bitrate, frame rate) — using the hero credits' typography
/// (`CreditEntry`). Columns render only when they have content; the whole
/// section renders nothing when every column is empty.
struct MediaInfoSection: View {
    @Environment(\.theme) private var theme

    let item: MediaItem

    var body: some View {
        let information = informationEntries
        let languages = languageEntries
        let fileName = item.technicalInfo?.fileName
        let fileFacts = fileFactEntries

        if !information.isEmpty || !languages.isEmpty || fileName != nil || !fileFacts.isEmpty {
            HStack(alignment: .top, spacing: SpacingTokens.xl) {
                column(LocalizedStringResource("detail.info.column.information", bundle: #bundle, comment: "Heading of the detail page column of general facts."), icon: "info.circle", entries: information)
                column(LocalizedStringResource("detail.info.column.languages", bundle: #bundle, comment: "Heading of the detail page column of audio and subtitle languages."), icon: "globe", entries: languages)
                fileColumn(name: fileName, facts: fileFacts)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpacingTokens.screenPadding)
        }
    }

    /// Column header treatment, matching the shelves' (`ContentShelf`):
    /// accent icon + headline title.
    private func header(_ title: LocalizedStringResource, icon: String) -> some View {
        HStack(spacing: SpacingTokens.xs) {
            Image(systemName: icon)
                .foregroundStyle(theme.accent)
            Text(title)
                .jsStyle(.headline)
                .foregroundStyle(theme.primary)
        }
    }

    /// A titled column of credit entries.
    @ViewBuilder
    private func column(_ title: LocalizedStringResource, icon: String, entries: [Entry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header(title, icon: icon)
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    ForEach(entries, id: \.label.key) { entry in
                        CreditEntry(label: entry.label, value: entry.value, lineLimit: 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// The File column: the file name gets the full column width (long release
    /// names need the room), and the short facts pack into a two-column grid
    /// beneath it.
    @ViewBuilder
    private func fileColumn(name: String?, facts: [Entry]) -> some View {
        if name != nil || !facts.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header(LocalizedStringResource("detail.info.column.file", bundle: #bundle, comment: "Heading of the detail page column of media file facts."), icon: "internaldrive")
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    if let name {
                        CreditEntry(label: LocalizedStringResource("detail.info.fileName", bundle: #bundle, comment: "Eyebrow over the media file’s name. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), value: name, lineLimit: 3)
                    }
                    if !facts.isEmpty {
                        // Pack the facts into two-per-row pairs, keyed by the
                        // row's leading label — content identity, not position,
                        // so a change of item doesn't reuse a row's identity for
                        // a different fact.
                        let rows = stride(from: 0, to: facts.count, by: 2).map { index in
                            (leading: facts[index], trailing: index + 1 < facts.count ? facts[index + 1] : nil)
                        }
                        Grid(alignment: .topLeading, horizontalSpacing: SpacingTokens.lg, verticalSpacing: SpacingTokens.sm) {
                            ForEach(rows, id: \.leading.label.key) { row in
                                GridRow {
                                    CreditEntry(label: row.leading.label, value: row.leading.value)
                                    if let trailing = row.trailing {
                                        CreditEntry(label: trailing.label, value: trailing.value)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Entries

    /// A labelled fact: our own label over a value that is data
    typealias Entry = (label: LocalizedStringResource, value: String)

    private var informationEntries: [Entry] {
        var entries: [Entry] = []
        // Episodes lead with where they sit in their show.
        if item.type == .episode {
            if let series = item.seriesName {
                entries.append((LocalizedStringResource("detail.info.series", bundle: #bundle, comment: "Eyebrow over the series an episode belongs to. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), series))
            }
            if let season = item.parentIndexNumber, let episode = item.indexNumber {
                entries.append((LocalizedStringResource("detail.info.episode", bundle: #bundle, comment: "Eyebrow over where an episode sits in its series. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), String(localized: LocalizedStringResource("detail.info.seasonEpisode \(season) \(episode)", bundle: #bundle, comment: "Where an episode sits in its series, such as “Season 2, Episode 4”. %1$lld is the season number, %2$lld the episode number."))))
            }
        }
        if let studios = item.studios, !studios.isEmpty {
            entries.append((studios.count > 1 ? LocalizedStringResource("detail.info.studios", bundle: #bundle, comment: "Eyebrow over several studio names. Small capitals label over a fact on a detail page; write it in capitals if the language has them.") : LocalizedStringResource("detail.info.studio", bundle: #bundle, comment: "Eyebrow over one studio name. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), studios.formatted(.list(type: .and))))
        }
        if let premiereDate = item.premiereDate {
            let label = switch item.type {
            case .series: LocalizedStringResource("detail.info.firstAired", bundle: #bundle, comment: "Eyebrow over a series’ first air date. Small capitals label over a fact on a detail page; write it in capitals if the language has them.")
            case .episode: LocalizedStringResource("detail.info.aired", bundle: #bundle, comment: "Eyebrow over an episode’s air date. Small capitals label over a fact on a detail page; write it in capitals if the language has them.")
            default: LocalizedStringResource("detail.info.released", bundle: #bundle, comment: "Eyebrow over a film’s release date. Small capitals label over a fact on a detail page; write it in capitals if the language has them.")
            }
            entries.append((label, premiereDate.formatted(date: .long, time: .omitted)))
        }
        if item.type == .series, let status = item.status {
            entries.append((LocalizedStringResource("detail.info.status", bundle: #bundle, comment: "Eyebrow over whether a series is still running. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), status))
        }
        if let genres = item.genres, !genres.isEmpty {
            entries.append((LocalizedStringResource("detail.info.genres", bundle: #bundle, comment: "Eyebrow over the genre names. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), genres.formatted(.list(type: .and))))
        }
        return entries
    }

    private var languageEntries: [Entry] {
        guard let tech = item.technicalInfo else { return [] }
        var entries: [Entry] = []
        if let original = tech.originalAudioLanguage {
            entries.append((LocalizedStringResource("detail.info.originalAudio", bundle: #bundle, comment: "Eyebrow over the original audio language. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), original))
        }
        if !tech.audioLanguages.isEmpty {
            entries.append((LocalizedStringResource("detail.info.audio", bundle: #bundle, comment: "Eyebrow over the audio track languages. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), tech.audioLanguages.formatted(.list(type: .and))))
        }
        if !tech.subtitleLanguages.isEmpty {
            entries.append((LocalizedStringResource("detail.info.subtitles", bundle: #bundle, comment: "Eyebrow over the subtitle languages. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), tech.subtitleLanguages.formatted(.list(type: .and))))
        }
        return entries
    }

    /// Short file facts for the grid — everything but the file name.
    private var fileFactEntries: [Entry] {
        guard let tech = item.technicalInfo else { return [] }
        var entries: [Entry] = []
        if let bytes = tech.fileSizeBytes {
            entries.append((LocalizedStringResource("detail.info.size", bundle: #bundle, comment: "Eyebrow over the file size. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), bytes.formatted(.byteCount(style: .file))))
        }
        if let container = tech.container {
            entries.append((LocalizedStringResource("detail.info.container", bundle: #bundle, comment: "Eyebrow over the file format, such as MKV. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), container))
        }
        if let codec = tech.videoCodec {
            entries.append((LocalizedStringResource("detail.info.videoCodec", bundle: #bundle, comment: "Eyebrow over the video codec, such as HEVC. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), codec))
        }
        if let bitrate = tech.bitrate {
            let mbps = (Double(bitrate) / 1_000_000)
                .formatted(.number.precision(.fractionLength(0 ... 1)))
            entries.append((LocalizedStringResource("detail.info.bitrate", bundle: #bundle, comment: "Eyebrow over the bitrate. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), String(localized: LocalizedStringResource("detail.info.mbps \(mbps)", bundle: #bundle, comment: "A bitrate in megabits per second. %@ is the number, already formatted, such as 12.5."))))
        }
        if let frameRate = tech.frameRate {
            let fps = frameRate.formatted(.number.precision(.fractionLength(0 ... 3)))
            entries.append((LocalizedStringResource("detail.info.frameRate", bundle: #bundle, comment: "Eyebrow over the frame rate. Small capitals label over a fact on a detail page; write it in capitals if the language has them."), String(localized: LocalizedStringResource("detail.info.fps \(fps)", bundle: #bundle, comment: "A frame rate in frames per second. %@ is the number, already formatted, such as 23.976."))))
        }
        return entries
    }
}

#if DEBUG
    #Preview("Standard") {
        ScrollView {
            MediaInfoSection(item: PreviewData.movie)
                .padding(.vertical, SpacingTokens.xl)
        }
        .previewCanvas()
    }

    #Preview("Horror") {
        ScrollView {
            MediaInfoSection(item: PreviewData.movie)
                .padding(.vertical, SpacingTokens.xl)
        }
        .previewCanvas(.horror)
    }

    #Preview("Action") {
        ScrollView {
            MediaInfoSection(item: PreviewData.movie)
                .padding(.vertical, SpacingTokens.xl)
        }
        .previewCanvas(.action)
    }

    #Preview("Video Store") {
        ScrollView {
            MediaInfoSection(item: PreviewData.movie)
                .padding(.vertical, SpacingTokens.xl)
        }
        .previewCanvas(.videoStore)
    }

    #Preview("Sci-Fi") {
        ScrollView {
            MediaInfoSection(item: PreviewData.movie)
                .padding(.vertical, SpacingTokens.xl)
        }
        .previewCanvas(.sciFi)
    }
#endif

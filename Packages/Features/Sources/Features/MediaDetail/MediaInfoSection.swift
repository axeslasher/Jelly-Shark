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
                column("Information", icon: "info.circle", entries: information)
                column("Languages", icon: "globe", entries: languages)
                fileColumn(name: fileName, facts: fileFacts)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpacingTokens.screenPadding)
        }
    }

    /// Column header treatment, matching the shelves' (`ContentShelf`):
    /// accent icon + headline title.
    private func header(_ title: String, icon: String) -> some View {
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
    private func column(_ title: String, icon: String, entries: [(label: String, value: String)]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header(title, icon: icon)
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    ForEach(entries, id: \.label) { entry in
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
    private func fileColumn(name: String?, facts: [(label: String, value: String)]) -> some View {
        if name != nil || !facts.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header("File", icon: "internaldrive")
                VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                    if let name {
                        CreditEntry(label: "File Name", value: name, lineLimit: 3)
                    }
                    if !facts.isEmpty {
                        Grid(alignment: .topLeading, horizontalSpacing: SpacingTokens.lg, verticalSpacing: SpacingTokens.sm) {
                            ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { index in
                                GridRow {
                                    CreditEntry(label: facts[index].label, value: facts[index].value)
                                    if index + 1 < facts.count {
                                        CreditEntry(label: facts[index + 1].label, value: facts[index + 1].value)
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

    private var informationEntries: [(label: String, value: String)] {
        var entries: [(String, String)] = []
        if let studios = item.studios, !studios.isEmpty {
            entries.append((studios.count > 1 ? "Studios" : "Studio", studios.formatted(.list(type: .and))))
        }
        if let premiereDate = item.premiereDate {
            entries.append((
                item.type == .series ? "First Aired" : "Released",
                premiereDate.formatted(date: .long, time: .omitted),
            ))
        }
        if item.type == .series, let status = item.status {
            entries.append(("Status", status))
        }
        if let genres = item.genres, !genres.isEmpty {
            entries.append(("Genres", genres.joined(separator: ", ")))
        }
        return entries
    }

    private var languageEntries: [(label: String, value: String)] {
        guard let tech = item.technicalInfo else { return [] }
        var entries: [(String, String)] = []
        if let original = tech.originalAudioLanguage {
            entries.append(("Original Audio", original))
        }
        if !tech.audioLanguages.isEmpty {
            entries.append(("Audio", tech.audioLanguages.joined(separator: ", ")))
        }
        if !tech.subtitleLanguages.isEmpty {
            entries.append(("Subtitles", tech.subtitleLanguages.joined(separator: ", ")))
        }
        return entries
    }

    /// Short file facts for the grid — everything but the file name.
    private var fileFactEntries: [(label: String, value: String)] {
        guard let tech = item.technicalInfo else { return [] }
        var entries: [(String, String)] = []
        if let bytes = tech.fileSizeBytes {
            entries.append(("Size", bytes.formatted(.byteCount(style: .file))))
        }
        if let container = tech.container {
            entries.append(("Container", container))
        }
        if let codec = tech.videoCodec {
            entries.append(("Video Codec", codec))
        }
        if let bitrate = tech.bitrate {
            let mbps = (Double(bitrate) / 1_000_000)
                .formatted(.number.precision(.fractionLength(0 ... 1)))
            entries.append(("Bitrate", "\(mbps) Mbps"))
        }
        if let frameRate = tech.frameRate {
            let fps = frameRate.formatted(.number.precision(.fractionLength(0 ... 3)))
            entries.append(("Frame Rate", "\(fps) fps"))
        }
        return entries
    }
}

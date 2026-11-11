import DesignSystem
import JellyfinKit
import SwiftUI

/// The words Live TV screens share for a channel and what it is showing.
enum LiveTVText {
    /// "4 Star Trek", or just the name when the tuner gave no number
    static func channelLabel(_ channel: LiveChannel) -> String {
        [channel.number, channel.name].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "S1 E26", when the guide carries both numbers
    static func episodeCode(_ program: LiveProgram) -> String? {
        guard let season = program.seasonNumber, let episode = program.episodeNumber else { return nil }
        return "S\(season) E\(episode)"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static let noProgramInfo = LocalizedStringResource(
        "liveTV.noProgramInfo",
        bundle: #bundle,
        comment: "Shown for a live TV channel when the guide has no programme for the time in question.",
    )

    /// The playing item the system player describes: the programme when the
    /// guide knows it, the bare channel otherwise. Built as a `MediaItem`
    /// because that is what the player's metadata is made from; the second
    /// line rides in `tagline`, which is where that code reads it for
    /// anything that is not an episode.
    static func nowPlayingItem(channel: LiveChannel, program: LiveProgram?) -> MediaItem {
        guard let program else {
            return channel.asMediaItem
        }
        let secondLine = [program.episodeTitle, episodeCode(program), channelLabel(channel)]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return MediaItem(
            id: channel.id,
            name: program.name,
            type: .tvChannel,
            overview: program.overview,
            officialRating: program.officialRating,
            tagline: secondLine,
            genres: program.genres,
        )
    }
}

extension JellyfinClientProtocol {
    /// Artwork for a channel card: the programme's own image when the guide
    /// has one, else the channel logo.
    func liveArtworkURL(channel: LiveChannel, program: LiveProgram?, maxWidth: Int) -> URL? {
        if let program, let tag = program.imageTag {
            return getImageURL(itemId: program.id, imageType: .primary, tag: tag, maxWidth: maxWidth, maxHeight: nil)
        }
        if let tag = channel.imageTag {
            return getImageURL(itemId: channel.id, imageType: .primary, tag: tag, maxWidth: maxWidth, maxHeight: nil)
        }
        return nil
    }
}

/// A channel as a wide play-on-select card: what is on, how far through it
/// is, and a second line the caller chooses. Used by Home's On Air Now shelf
/// and the player's guide strip.
struct LiveChannelCard: View {
    enum SecondLine {
        /// "4 Star Trek · until 2:23 PM", for a shelf of what is on now
        case channelAndEnd
        /// "4 Star Trek · Next: Letterkenny 2:06 PM", for choosing a channel
        case channelAndNext(LiveProgram?)
    }

    let channel: LiveChannel
    let program: LiveProgram?
    let now: Date
    let secondLine: SecondLine
    let client: (any JellyfinClientProtocol)?
    var width: CGFloat = 440
    var focusBinding: FocusState<ShelfFocusID?>.Binding?
    var focusID: ShelfFocusID?
    let onPlay: () -> Void

    var body: some View {
        ArtworkShelfItem(
            url: client?.liveArtworkURL(channel: channel, program: program, maxWidth: 1000),
            title: program?.name ?? channel.name,
            subtitle: subtitle,
            captionAlignment: .leading,
            placeholderIcon: "antenna.radiowaves.left.and.right",
            aspectRatio: 16.0 / 9.0,
            width: width,
            progress: program?.progress(at: now),
            focusBinding: focusBinding,
            focusID: focusID,
            action: onPlay,
        )
    }

    private var subtitle: String {
        let label = LiveTVText.channelLabel(channel)
        switch secondLine {
        case .channelAndEnd:
            // The title already shows the channel name when nothing is
            // scheduled, so the second line says why there is no programme.
            guard let program else {
                return String(localized: LiveTVText.noProgramInfo)
            }
            let end = LiveTVText.time(program.endDate)
            return String(
                localized: "liveTV.card.channelUntil \(label) \(end)",
                bundle: #bundle,
                comment: "Second line of a live TV card. First value is the channel, second is when the programme ends.",
            )
        case let .channelAndNext(next):
            guard let next else { return label }
            let start = LiveTVText.time(next.startDate)
            return String(
                localized: "liveTV.card.channelNext \(label) \(next.name) \(start)",
                bundle: #bundle,
                comment: "Second line of a live TV card in the player's guide. Values: the channel, the next programme, and when it starts.",
            )
        }
    }
}

#if DEBUG
    private struct LiveChannelCardPreview: View {
        var body: some View {
            let now = Date.now
            let channel = LiveChannel(id: "4", name: "Star Trek", number: "4")
            let program = LiveProgram(
                id: "p",
                channelId: "4",
                name: "Star Trek",
                episodeTitle: "Errand of Mercy",
                startDate: now.addingTimeInterval(-1800),
                endDate: now.addingTimeInterval(1200),
            )
            HStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                LiveChannelCard(channel: channel, program: program, now: now, secondLine: .channelAndEnd, client: nil) {}
                LiveChannelCard(
                    channel: LiveChannel(id: "2", name: "Ashley TV", number: "2"),
                    program: nil,
                    now: now,
                    secondLine: .channelAndEnd,
                    client: nil,
                ) {}
            }
            .padding(SpacingTokens.xl)
        }
    }

    #Preview("Standard", traits: .featuresEnvironment(theme: .standard)) { LiveChannelCardPreview() }
    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) { LiveChannelCardPreview() }
    #Preview("Action", traits: .featuresEnvironment(theme: .action)) { LiveChannelCardPreview() }
    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) { LiveChannelCardPreview() }
    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) { LiveChannelCardPreview() }
#endif

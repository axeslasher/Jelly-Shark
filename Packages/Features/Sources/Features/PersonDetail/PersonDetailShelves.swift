import DesignSystem
import JellyfinKit
import SwiftUI

/// A person page filmography shelf. Renders nothing until items arrive.
///
/// Movies and series render poster cards that navigate to their detail page;
/// episodes render episode cards (with the series name for context, since
/// there's no series page framing them here) that play immediately on click,
/// matching the Episodes shelf on a series page.
///
/// `SearchShelfSection` looks like this one and behaves differently on
/// purpose: its episodes push to the episode page rather than play, because
/// search is a navigational surface. That is why the two are separate views
/// rather than one shared shelf — sharing would mean dragging this playback
/// binding onto a screen that has no player.
struct PersonShelfSection: View {
    @Environment(AppSession.self) private var session

    enum Style {
        case poster
        case episode
    }

    let title: String
    let icon: String
    let items: [MediaItem]
    let style: Style
    @Binding var playbackItem: PlaybackRequest?

    var body: some View {
        if !items.isEmpty {
            ContentShelf(title, icon: icon) {
                ForEach(items) { item in
                    switch style {
                    case .poster:
                        item.posterShelfItem(client: session.client)
                    case .episode:
                        item.episodeShelfItem(client: session.client, showsSeriesName: true) {
                            playbackItem = PlaybackRequest(item: item)
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
    private struct PersonShelfSectionPreview: View {
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                        PersonShelfSection(
                            title: "Movies",
                            icon: "film",
                            items: Array(PreviewData.shelf.prefix(5)),
                            style: .poster,
                            playbackItem: .constant(nil),
                        )
                        PersonShelfSection(
                            title: "Episodes",
                            icon: "tv",
                            items: Array(PreviewData.seasonEpisodes.prefix(4)),
                            style: .episode,
                            playbackItem: .constant(nil),
                        )
                    }
                }
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        PersonShelfSectionPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        PersonShelfSectionPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        PersonShelfSectionPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        PersonShelfSectionPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        PersonShelfSectionPreview()
    }
#endif

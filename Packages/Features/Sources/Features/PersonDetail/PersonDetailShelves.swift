import DesignSystem
import JellyfinKit
import SwiftUI

/// A person page filmography shelf. Renders nothing until items arrive.
///
/// Movies and series render poster cards that navigate to their detail page;
/// episodes render episode cards (with the series name for context, since
/// there's no series page framing them here) that play immediately on click,
/// matching the Episodes shelf on a series page.
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
    @Binding var playbackItem: MediaItem?

    var body: some View {
        if !items.isEmpty {
            ContentShelf(title, icon: icon) {
                ForEach(items) { item in
                    switch style {
                    case .poster:
                        item.posterShelfItem(client: session.client)
                    case .episode:
                        item.episodeShelfItem(client: session.client, showsSeriesName: true) {
                            playbackItem = item
                        }
                    }
                }
            }
        }
    }
}

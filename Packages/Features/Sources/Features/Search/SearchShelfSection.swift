import DesignSystem
import JellyfinKit
import SwiftUI

/// One grouped search-results shelf. Renders nothing until items arrive, so a
/// type with no matches leaves no empty row and no "0 results" header.
///
/// Deliberately *not* `PersonShelfSection`, which this otherwise mirrors: that
/// one takes a playback binding and plays episodes on select. Search is a
/// navigational surface — every card here, episodes included, pushes to its
/// detail page — so this shelf has no playback coupling at all and needs
/// neither the binding nor the cover. The two shelves look alike and behave
/// differently on purpose.
struct SearchShelfSection: View {
    @Environment(AppSession.self) private var session

    enum Style {
        /// Movies and series: 2:3 poster cards.
        case poster
        /// Episodes: 16:9 stills with the series name as the subtitle.
        case landscape
    }

    let title: String
    let icon: String
    let items: [MediaItem]
    let style: Style

    var body: some View {
        if !items.isEmpty {
            ContentShelf(title, icon: icon) {
                ForEach(items) { item in
                    switch style {
                    case .poster:
                        item.posterShelfItem(client: session.client)
                    case .landscape:
                        item.landscapeShelfItem(client: session.client)
                    }
                }
            }
        }
    }
}

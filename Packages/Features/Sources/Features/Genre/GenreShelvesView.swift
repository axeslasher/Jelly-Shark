import DesignSystem
import SwiftUI

/// Renders the Home "Browse {library} by genre" shelves. A pure renderer — the
/// genre lists are built by `GenreShelvesViewModel`, owned by `HomeView` so
/// loading stays eager (its top-level `.task` always runs). Each card
/// (`GenreCardView`) lazily loads its own backdrop.
struct GenreShelvesView: View {
    let shelves: [GenreShelvesViewModel.Shelf]

    var body: some View {
        ForEach(shelves) { shelf in
            ContentShelf("Browse \(shelf.library.name) by genre", icon: shelf.library.systemImageName) {
                ForEach(shelf.genres, id: \.self) { genre in
                    GenreCardView(library: shelf.library, genre: genre)
                }
            }
        }
    }
}

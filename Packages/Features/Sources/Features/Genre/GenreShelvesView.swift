import DesignSystem
import SwiftUI

/// Renders the Home "Browse {library} by genre" shelves. A pure renderer — the
/// genre lists are built by `GenreShelvesViewModel`, owned by `HomeView` so
/// loading stays eager (its top-level `.task` always runs). Each card
/// (`GenreCardView`) lazily loads its own backdrop.
struct GenreShelvesView: View {
    let shelves: [GenreShelvesViewModel.Shelf]
    let status: GenreShelvesViewModel.Status
    /// Retry action for the failed notice (`GenreShelvesViewModel.retry`).
    let onRetry: () -> Void

    var body: some View {
        ForEach(shelves) { shelf in
            ContentShelf("Browse \(shelf.library.name) by genre", icon: shelf.library.systemImageName) {
                ForEach(shelf.genres, id: \.self) { genre in
                    GenreCardView(library: shelf.library, genre: genre)
                }
            }
        }
        // A partial failure still renders the surviving shelves above (the
        // view model re-arms its own reload); the notice is for the
        // nothing-survived case only.
        if shelves.isEmpty, status.isFailed {
            FailedShelfNotice(title: "Browse by genre", icon: "theatermasks.fill", retry: onRetry)
        }
    }
}

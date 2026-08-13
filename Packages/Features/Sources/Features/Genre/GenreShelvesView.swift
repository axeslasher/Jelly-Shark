import DesignSystem
import SwiftUI
#if DEBUG
    import JellyfinKit // The preview's Library fixture; the view itself doesn't need it.
#endif

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

#if DEBUG
    private struct GenreShelvesViewPreview: View {
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                        GenreShelvesView(
                            shelves: [GenreShelvesViewModel.Shelf(
                                library: Library(id: "preview-lib", name: "Movies", collectionType: .movies),
                                genres: ["Horror", "Comedy", "Drama", "Documentary"],
                            )],
                            status: .loaded,
                            onRetry: {},
                        )

                        // Nothing survived: the failed notice with Retry.
                        GenreShelvesView(shelves: [], status: .failed("offline"), onRetry: {})
                    }
                }
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        GenreShelvesViewPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        GenreShelvesViewPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        GenreShelvesViewPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        GenreShelvesViewPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        GenreShelvesViewPreview()
    }
#endif

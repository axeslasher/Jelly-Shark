import DesignSystem
import JellyfinKit
import SwiftUI

/// A single library card on the Libraries grid: the library's name over a
/// backdrop borrowed from one of its items (#138).
///
/// The same component a genre card wears, on purpose — a library and a genre
/// are both "a slice of the collection with no picture of its own", and the
/// grid reads as one family with Home's genre shelves because of it.
///
/// The choice of backdrop is remembered by `GenreBackdropStore` on the session,
/// for as long as a profile's cache is active, so a card scrolling back into
/// view — or the whole grid returning from a library — costs no request and
/// keeps the same face. Without a cache (previews, a cache-less composition
/// root) the choice dies with the view. Selecting the card pushes the library's
/// grid via the `Library` value the enclosing stack resolves.
struct LibraryCardView: View {
    @Environment(AppSession.self) private var session

    let library: Library
    let width: CGFloat

    @State private var viewModel = LibraryCardViewModel()

    var body: some View {
        GenreShelfItem(
            title: library.name,
            backdropURL: viewModel.backdropURL(client: session.client),
            blurHash: viewModel.blurHash,
            width: width,
            value: library,
            onBackdropUnavailable: {
                Task { await viewModel.backdropUnavailable(client: session.client, library: library) }
            },
        )
        .task {
            // The store lives on the session, so the handover happens here
            // rather than at init — `@State` cannot read the environment when
            // it builds the view model.
            viewModel.attach(store: session.genreBackdrops)
            await viewModel.load(client: session.client, library: library)
        }
    }
}

#if DEBUG
    /// The preview trait's session has no client, so the sample fetch no-ops
    /// and each card renders its seeded gradient wash — the same face a library
    /// with no artwork shows in production, and the one worth checking across
    /// five themes. The sampled-backdrop state needs a real server, so it is a
    /// device check rather than a canvas one.
    ///
    /// Sized to `LibrariesGridView`'s card width so the label's wrapping and
    /// the wash's proportions read here the way they will on the grid.
    private struct LibraryCardViewPreview: View {
        var body: some View {
            NavigationStack {
                HStack(spacing: SpacingTokens.cardGap) {
                    LibraryCardView(
                        library: Library(id: "preview-movies", name: "Movies", collectionType: .movies),
                        width: 380,
                    )
                    LibraryCardView(
                        library: Library(id: "preview-shows", name: "TV Shows", collectionType: .tvshows),
                        width: 380,
                    )
                }
                .padding(SpacingTokens.screenPadding)
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        LibraryCardViewPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        LibraryCardViewPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        LibraryCardViewPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        LibraryCardViewPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        LibraryCardViewPreview()
    }
#endif

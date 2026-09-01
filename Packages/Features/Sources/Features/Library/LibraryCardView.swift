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

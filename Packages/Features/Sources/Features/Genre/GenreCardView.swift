import DesignSystem
import JellyfinKit
import SwiftUI

/// A single genre card that lazily loads its representative backdrop. Because the
/// shelf is a `LazyHStack`, this view is only realized as it scrolls into view,
/// so each card fetches exactly one small page for its genre on demand —
/// coverage never depends on a single up-front sample. Tapping navigates to the
/// library grid pre-filtered to the genre via a `GenreFilter` value.
struct GenreCardView: View {
    @Environment(AppSession.self) private var session

    let library: Library
    let genre: String

    @State private var backdropURL: URL?
    @State private var blurHash: String?
    @State private var didLoad = false

    var body: some View {
        GenreShelfItem(
            title: genre,
            backdropURL: backdropURL,
            blurHash: blurHash,
            value: GenreFilter(library: library, genre: genre),
        )
        .task {
            // Guard against the `.task` re-firing on reappearance — the backdrop,
            // once chosen, should stay put (and the image itself is URLCache-backed).
            guard !didLoad else { return }
            didLoad = true
            await loadBackdrop()
        }
    }

    /// Pick a random item's backdrop to represent the genre. There's no
    /// server-side random sort, so fetch a small page and choose among the items
    /// that actually have a backdrop. A no-op (mesh-only card) when the genre has
    /// no artwork.
    private func loadBackdrop() async {
        guard let client = session.client else { return }
        guard let page = try? await client.getLibraryItems(
            libraryId: library.id,
            itemTypes: library.collectionType?.gridItemTypes,
            query: LibraryQuery(genres: [genre]),
            limit: 12,
            startIndex: 0,
        ) else { return }

        let withBackdrop = page.items.filter { client.backdropURL(for: $0) != nil }
        guard let item = withBackdrop.randomElement() else { return }
        backdropURL = client.backdropURL(for: item)
        blurHash = item.backdropBlurHash
    }
}

import JellyfinKit

/// Navigation value for a genre card: opens `LibraryItemsView` for `library`
/// pre-filtered to `genre`. Pushed by a `GenreShelfItem` and resolved by the
/// `navigationDestination(for: GenreFilter.self)` registered in `RootView`.
struct GenreFilter: Hashable {
    let library: Library
    let genre: String
}

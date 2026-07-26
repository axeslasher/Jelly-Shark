import JellyfinKit

/// Navigation value for a genre card: opens `LibraryItemsView` for `library`
/// pre-filtered to `genre`. Pushed by a `GenreShelfItem` and resolved by the
/// `navigationDestination(for: GenreFilter.self)` registered in `RootView`.
///
/// A nil `library` browses the genre across every library — what a card on a
/// media detail page means, since a detail page has no library of its own to
/// scope to (#108). Home's cards always carry one.
struct GenreFilter: Hashable {
    let library: Library?
    let genre: String
}

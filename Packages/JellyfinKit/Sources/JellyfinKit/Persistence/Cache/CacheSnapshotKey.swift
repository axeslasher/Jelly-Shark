/// Which cached payload a snapshot row holds. Each case names exactly one
/// blob per scope; the payload type behind each key is fixed by its writer
/// (`CachingJellyfinClient` for every server-response case, `HomeViewModel`
/// for `homeSnapshot`, `Features`' `GenreBackdropStore` for
/// `genreBackdrops`).
///
/// `storageKey` strings are part of the on-disk format — changing one
/// requires a `MediaCacheStore.schemaVersion` bump.
public enum CacheSnapshotKey: Sendable, Hashable {
    /// The connected `User`, so a restored session can show a profile
    /// without waiting for validation
    case currentUser

    /// The user's `[Library]` list — what instant connect renders tabs from
    case libraries

    /// Home's `CachedHomeSnapshot`: sections plus the derived hero curation
    case homeSnapshot

    /// The first `MediaItemPage` of a library grid under the default query
    /// (name ascending, no filters); nil is the unscoped all-libraries grid
    case libraryFirstPage(libraryID: String?)

    /// One item's detail-fetch `MediaItem`
    case mediaDetail(itemID: String)

    /// The genre cards' remembered `(library, genre) → item` backdrop picks,
    /// as one map per scope. Scoped rather than global (#207) so one
    /// profile's picks can't render on another's cards.
    case genreBackdrops

    var storageKey: String {
        switch self {
        case .currentUser: "currentUser"
        case .libraries: "libraries"
        case .homeSnapshot: "home"
        case let .libraryFirstPage(libraryID): "libraryFirstPage\u{1F}\(libraryID ?? "")"
        case let .mediaDetail(itemID): "mediaDetail\u{1F}\(itemID)"
        case .genreBackdrops: "genreBackdrops"
        }
    }

    /// Coarse payload family, stored on the row so unbounded families can be
    /// count-pruned without parsing entry keys
    var kind: String {
        switch self {
        case .currentUser: "currentUser"
        case .libraries: "libraries"
        case .homeSnapshot: "home"
        case .libraryFirstPage: "libraryFirstPage"
        case .mediaDetail: Self.mediaDetailKind
        case .genreBackdrops: "genreBackdrops"
        }
    }

    static let mediaDetailKind = "mediaDetail"
}

public extension LibraryQuery {
    /// Whether this query is the default browse — name ascending, no
    /// filters — whose first page is the one grid state the cache persists.
    /// Shared between the write side (`CachingJellyfinClient`) and the
    /// hydration side so the two conditions can never drift apart.
    var isDefaultBrowse: Bool {
        !isFiltering && sort == .name && direction == .ascending
    }
}

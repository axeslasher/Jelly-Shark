/// Which cached payload a snapshot row holds. Each case names exactly one
/// blob per scope; the payload type behind each key is fixed by its writer
/// (`CachingJellyfinClient` for the parameter-keyed cases, `HomeViewModel`
/// for `homeSnapshot`).
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

    var storageKey: String {
        switch self {
        case .currentUser: "currentUser"
        case .libraries: "libraries"
        case .homeSnapshot: "home"
        case let .libraryFirstPage(libraryID): "libraryFirstPage\u{1F}\(libraryID ?? "")"
        case let .mediaDetail(itemID): "mediaDetail\u{1F}\(itemID)"
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
        }
    }

    static let mediaDetailKind = "mediaDetail"
}

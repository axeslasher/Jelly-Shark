import Foundation

/// Everything Home needs to render its first frame, captured after a fully
/// successful load.
///
/// One blob rather than per-section rows, on purpose: Home reveals all of
/// its sections at once (the skeleton drops in a single turn so the tvOS
/// focus engine has the full page to land on), so hydration must be
/// all-or-nothing too — a single row makes partial snapshots unrepresentable.
/// The hero list rides along because it is *derived* state: curation probes
/// image widths over the network, and a cached render must show the heroes
/// that were actually chosen last time, not re-derive them offline.
public struct CachedHomeSnapshot: Sendable, Codable {
    /// One "Recently Added in <library>" shelf
    public struct Shelf: Sendable, Codable {
        public let library: Library
        public let items: [MediaItem]

        public init(library: Library, items: [MediaItem]) {
            self.library = library
            self.items = items
        }
    }

    public let resume: [MediaItem]
    public let nextUp: [MediaItem]
    public let shelves: [Shelf]
    public let heroItems: [MediaItem]
    public let episodePrimaryHeroIds: [String]
    public let seriesLastPlayedDates: [String: Date]

    public init(
        resume: [MediaItem],
        nextUp: [MediaItem],
        shelves: [Shelf],
        heroItems: [MediaItem],
        episodePrimaryHeroIds: [String],
        seriesLastPlayedDates: [String: Date],
    ) {
        self.resume = resume
        self.nextUp = nextUp
        self.shelves = shelves
        self.heroItems = heroItems
        self.episodePrimaryHeroIds = episodePrimaryHeroIds
        self.seriesLastPlayedDates = seriesLastPlayedDates
    }
}

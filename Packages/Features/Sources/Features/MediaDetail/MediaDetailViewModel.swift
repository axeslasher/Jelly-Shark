import Foundation
import JellyfinKit
import Observation

/// Loads a media detail page's server-side content: the full item (which
/// carries cast & crew), the per-type sections (seasons/episodes for series,
/// contents for collections), and the More Like This enrichment.
///
/// The screen-defining fetches share one `status` — they hit the same server
/// in the same instant, and the failed notice's Retry re-runs them together,
/// so per-facet statuses would only add UI branches with no distinct
/// recovery path. Genuinely optional enrichment (similar items, the next-up
/// resolution with its first-episode fallback) keeps `try?` and never
/// touches `status`.
@Observable
@MainActor
public final class MediaDetailViewModel {
    /// Lifecycle of the core load. No `.empty` case: the passed-in stub
    /// always renders, so a fetch that returns little just makes a sparse
    /// page — only a *failed* fetch needs surfacing.
    public enum Status: Equatable {
        case loading
        case loaded
        case failed(String)

        var isFailed: Bool {
            if case .failed = self {
                return true
            }
            return false
        }
    }

    // MARK: - Outputs

    /// The detailed fetch; nil until it lands (or when it failed), so the
    /// view can keep rendering the stub it was pushed with.
    public private(set) var detailedItem: MediaItem?

    /// Series-only: the season list, every episode in series order (one
    /// continuous shelf spans all seasons), and the episode the hero Play
    /// button resolves to.
    public private(set) var seasons: [MediaItem] = []
    public private(set) var episodes: [MediaItem] = []
    public private(set) var nextUpEpisode: MediaItem?

    /// BoxSet-only: the collection's contents, in release order.
    public private(set) var collectionItems: [MediaItem] = []

    /// Credits derived once when the detailed item lands, rather than
    /// re-filtering `people` on every body evaluation.
    public private(set) var directors: [CastMember] = []
    public private(set) var topCast: [CastMember] = []

    public private(set) var similarItems: [MediaItem] = []

    /// Optimistic watched override for the hero's own item. While `nil` the
    /// hero reflects the fetched `userData`; a toggle sets it and it reverts
    /// on a failed server call. The hero's eye toggle and the Play-button
    /// label both read through it, so they agree on the pending state.
    public private(set) var heroPlayedOverride: Bool?

    /// Optimistic favorite override for the hero's own item; same lifecycle.
    public private(set) var heroFavoriteOverride: Bool?

    public private(set) var status: Status = .loading

    /// Watched state the hero shows: the pending optimistic value if any,
    /// otherwise Jellyfin's stored status for the page's item.
    public var heroIsPlayed: Bool {
        heroPlayedOverride ?? (detailedItem ?? item)?.userData?.played ?? false
    }

    /// Favorite state the hero shows: optimistic value if any, otherwise
    /// Jellyfin's stored status.
    public var heroIsFavorite: Bool {
        heroFavoriteOverride ?? (detailedItem ?? item)?.userData?.isFavorite ?? false
    }

    // MARK: - Configuration

    private var client: (any JellyfinClientProtocol)?
    private var item: MediaItem?

    /// Reload only when the connection or page item actually changes
    /// (mirrors `HomeViewModel`); a failed load re-arms this so the next
    /// appearance retries.
    private var needsLoad = true
    private var loadGeneration = 0

    /// Crew functions that some servers stuff into a person's `role` while
    /// still tagging `kind` as "Actor". Used to recognize crew (and exclude
    /// them from the billed-cast list) regardless of which field carries the
    /// credit.
    private static let crewRoles: Set<String> = [
        "Director", "Writer", "Producer",
        "Executive Producer", "Co-Producer", "Co-Executive Producer",
    ]

    public init() {}

    // MARK: - Loading

    /// Attach the client and page item (called by the view on appearance and
    /// when the pushed item changes). Only an actual change schedules a load.
    public func attach(client: (any JellyfinClientProtocol)?, item: MediaItem) {
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let itemChanged = item.id != self.item?.id
        self.client = client
        self.item = item
        if clientChanged || itemChanged {
            needsLoad = true
        }
    }

    /// Load the page. No-op once loaded for the current client + item.
    public func load() async {
        guard needsLoad else { return }
        needsLoad = false
        loadGeneration += 1
        let generation = loadGeneration

        // Reset so a reused view (item.id change) doesn't show the previous
        // item's seasons or collection contents while the new ones load.
        detailedItem = nil
        seasons = []
        episodes = []
        nextUpEpisode = nil
        collectionItems = []
        directors = []
        topCast = []
        similarItems = []
        heroPlayedOverride = nil
        heroFavoriteOverride = nil
        status = .loading

        // No client means the session is still being established (or was
        // torn down) — park at `.loading`; the stub keeps the page rendered.
        guard let client, let item else { return }

        do {
            let detail = try await client.getMediaItem(itemId: item.id)
            guard generation == loadGeneration else { return }
            detailedItem = detail
            deriveCredits()

            if item.type == .series {
                async let seasonsFetch = client.getSeasons(seriesId: item.id)
                async let episodesFetch = client.getEpisodes(seriesId: item.id, seasonId: nil)
                async let nextUpFetch = client.getNextUpEpisode(seriesId: item.id)
                let (fetchedSeasons, fetchedEpisodes) = try await (seasonsFetch, episodesFetch)
                // Next-up is enrichment: the Play button falls back to the
                // first episode, so a failure here must not fail the page.
                let nextUp = await (try? nextUpFetch) ?? nil
                guard generation == loadGeneration else { return }
                seasons = fetchedSeasons
                episodes = fetchedEpisodes
                nextUpEpisode = nextUp
            }

            if item.type == .boxSet {
                let items = try await client.getCollectionItems(collectionId: item.id)
                guard generation == loadGeneration else { return }
                collectionItems = items
            }

            status = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            status = .failed(error.localizedDescription)
            needsLoad = true
        }

        // More Like This is enrichment: a failure renders no shelf, never an
        // error — and it loads even alongside a failed core so a retry that
        // recovers doesn't wait on it.
        let similar = await (try? client.getSimilarItems(itemId: item.id, limit: 12)) ?? []
        guard generation == loadGeneration else { return }
        similarItems = similar
    }

    /// Re-run the core load now — the failed notice's Retry button.
    public func retry() async {
        needsLoad = true
        await load()
    }

    /// Playback changes server-side user data this page displays — resume
    /// position (hero Play/Resume button), watched flags on episode and
    /// collection cards, and next-up. `load()` only re-runs when the item id
    /// changes, so refresh in place when the player dismisses; unlike
    /// `load()`, nothing is blanked or re-statused first, so already-rendered
    /// shelves don't flash — which is why `try?` is right here: a failed
    /// refresh keeps the last-good data.
    public func refreshAfterPlayback() async {
        guard let client, let item else { return }
        loadGeneration += 1
        let generation = loadGeneration

        if let refreshed = try? await client.getMediaItem(itemId: item.id) {
            guard generation == loadGeneration else { return }
            detailedItem = refreshed
            deriveCredits()
        }

        if item.type == .series {
            async let episodesFetch = client.getEpisodes(seriesId: item.id, seasonId: nil)
            async let nextUpFetch = client.getNextUpEpisode(seriesId: item.id)
            let refreshedEpisodes = await (try? episodesFetch)
            let nextUp = await (try? nextUpFetch) ?? nil
            guard generation == loadGeneration else { return }
            if let refreshedEpisodes {
                episodes = refreshedEpisodes
            }
            nextUpEpisode = nextUp
        }

        // Watched flags on the collection cards (and the Play target's
        // first-unwatched resolution) change with playback too.
        if item.type == .boxSet {
            let refreshedItems = try? await client.getCollectionItems(collectionId: item.id)
            guard generation == loadGeneration else { return }
            if let refreshedItems {
                collectionItems = refreshedItems
            }
        }
    }

    // MARK: - User-Data Actions

    /// Optimistically flip the hero item's watched state, then persist;
    /// revert on failure.
    public func toggleHeroPlayed() async {
        guard let client, let item else { return }
        let target = !heroIsPlayed
        heroPlayedOverride = target
        do {
            if target {
                try await client.markPlayed(itemId: item.id)
            } else {
                try await client.markUnplayed(itemId: item.id)
            }
        } catch {
            heroPlayedOverride = !target
        }
    }

    /// Optimistically flip the hero item's favorite state, then persist;
    /// revert on failure.
    public func toggleHeroFavorite() async {
        guard let client, let item else { return }
        let target = !heroIsFavorite
        heroFavoriteOverride = target
        do {
            if target {
                try await client.markFavorite(itemId: item.id)
            } else {
                try await client.unmarkFavorite(itemId: item.id)
            }
        } catch {
            heroFavoriteOverride = !target
        }
    }

    /// Optimistically apply a watched-state change from an episode card's
    /// long-press menu, then persist; on success run the same in-place
    /// refresh as a finished playback, since watched flags move next-up and
    /// the hero's Play target. Reverts on failure.
    public func setPlayed(_ played: Bool, for target: MediaItem) async {
        guard let client else { return }
        replaceInSections(target.settingPlayed(played))
        do {
            if played {
                try await client.markPlayed(itemId: target.id)
            } else {
                try await client.markUnplayed(itemId: target.id)
            }
            await refreshAfterPlayback()
        } catch {
            replaceInSections(target)
        }
    }

    /// Optimistically apply a favorite change from an episode card's
    /// long-press menu, then persist; revert on failure.
    public func setFavorite(_ favorite: Bool, for target: MediaItem) async {
        guard let client else { return }
        replaceInSections(target.settingFavorite(favorite))
        do {
            if favorite {
                try await client.markFavorite(itemId: target.id)
            } else {
                try await client.unmarkFavorite(itemId: target.id)
            }
        } catch {
            replaceInSections(target)
        }
    }

    /// Swap the item (by id) into every section that carries it, so a card's
    /// badge and menu labels update in place wherever it appears.
    private func replaceInSections(_ target: MediaItem) {
        func swapping(_ items: [MediaItem]) -> [MediaItem] {
            items.map { $0.id == target.id ? target : $0 }
        }
        episodes = swapping(episodes)
        collectionItems = swapping(collectionItems)
        similarItems = swapping(similarItems)
        if nextUpEpisode?.id == target.id {
            nextUpEpisode = target
        }
    }

    // MARK: - Credits

    /// Directors: handles both standard data (`kind == "Director"`) and
    /// servers that report everyone as `kind == "Actor"` with the function in
    /// `role`. Top cast: first 3 billed actors, excluding mislabeled crew.
    private func deriveCredits() {
        let people = detailedItem?.people ?? []
        directors = people.filter { $0.kind == "Director" || $0.role == "Director" }
        topCast = Array(
            people
                .filter { $0.kind == "Actor" && !(($0.role).map(Self.crewRoles.contains) ?? false) }
                .prefix(3),
        )
    }
}

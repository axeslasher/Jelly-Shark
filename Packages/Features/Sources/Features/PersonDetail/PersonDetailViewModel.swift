import Foundation
import JellyfinKit
import Observation

/// Loads a person page's server-side content: the detailed person (biography,
/// life facts) and the three filmography shelves that are the page's body.
///
/// The filmography fetches are the screen-defining load, evaluated as one
/// combined status with partial survival (mirrors Home's Recently Added):
/// whatever succeeded renders, any failure re-arms a reload, and only a
/// failure that left nothing to show reports `.failed`. The person fetch is
/// enrichment — the header renders from the pushed `CastMember` stub
/// regardless — so it keeps `try?`.
@Observable
@MainActor
public final class PersonDetailViewModel {
    /// Lifecycle of the filmography load. No `.empty` case: empty shelves
    /// already render nothing, and a bare header over no filmography is the
    /// existing, deliberate state for people with no indexed credits.
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

    /// Detailed fetch; upgrades the header's metadata and biography.
    public private(set) var person: Person?

    public private(set) var movies: [MediaItem] = []
    public private(set) var series: [MediaItem] = []
    public private(set) var episodes: [MediaItem] = []

    /// Random filmography entry with a usable backdrop; drives the background.
    public private(set) var backdropItem: MediaItem?

    /// Optimistic override for the header's favorite toggle. While `nil` the
    /// button reflects Jellyfin's fetched state; a toggle sets it and it
    /// reverts on a failed server call.
    public private(set) var favoriteOverride: Bool?

    public private(set) var filmographyStatus: Status = .loading

    /// Favorite state the header shows: optimistic value if any, otherwise
    /// Jellyfin's stored status.
    public var isFavorite: Bool {
        favoriteOverride ?? person?.isFavorite ?? false
    }

    // MARK: - Configuration

    /// Items fetched per shelf: a few pages of horizontal scrolling without
    /// pagination, and three light queries per page load.
    private static let shelfLimit = 25

    private var client: (any JellyfinClientProtocol)?
    private var member: CastMember?

    /// Reload only when the connection or person actually changes (mirrors
    /// `HomeViewModel`); a failed load re-arms this so the next appearance
    /// retries.
    private var needsLoad = true
    private var loadGeneration = 0

    public init() {}

    // MARK: - Loading

    /// Attach the client and page person (called by the view on appearance
    /// and when the pushed member changes). Only an actual change schedules
    /// a load.
    public func attach(client: (any JellyfinClientProtocol)?, member: CastMember) {
        let clientChanged = (client as AnyObject?) !== (self.client as AnyObject?)
        let memberChanged = member.id != self.member?.id
        self.client = client
        self.member = member
        if clientChanged || memberChanged {
            needsLoad = true
        }
    }

    /// Load the page. No-op once loaded for the current client + member.
    public func load() async {
        guard needsLoad else { return }
        needsLoad = false
        loadGeneration += 1
        let generation = loadGeneration

        // Reset so a reused view (member.id change) doesn't show the previous
        // person's filmography while the new one loads.
        person = nil
        movies = []
        series = []
        episodes = []
        backdropItem = nil
        favoriteOverride = nil
        filmographyStatus = .loading

        // No client means the session is still being established (or was
        // torn down) — park at `.loading`; the stub header keeps rendering.
        guard let client, let member else { return }

        // A member without a server id has nothing fetchable — the stub
        // header is the whole page, and that's `.loaded`, not an error.
        guard member.hasServerId else {
            filmographyStatus = .loaded
            return
        }

        async let personFetch = client.getPerson(personId: member.id)
        async let moviesFetch = Self.fetchFilmography(
            client: client, personId: member.id, itemTypes: [.movie],
        )
        async let seriesFetch = Self.fetchFilmography(
            client: client, personId: member.id, itemTypes: [.series],
        )
        async let episodesFetch = Self.fetchFilmography(
            client: client, personId: member.id, itemTypes: [.episode],
        )

        // Enrichment: the header falls back to the stub on failure.
        let fetchedPerson = try? await personFetch

        let results = await [moviesFetch, seriesFetch, episodesFetch]
        guard generation == loadGeneration else { return }

        person = fetchedPerson
        movies = (try? results[0].get()) ?? []
        series = (try? results[1].get()) ?? []
        episodes = (try? results[2].get()) ?? []

        let firstError = results.compactMap { result -> String? in
            if case let .failure(error) = result {
                return error.localizedDescription
            }
            return nil
        }.first

        if firstError != nil {
            // Show what survived, but re-arm so the next appearance (or the
            // notice's Retry) refetches the gap; report failure only when
            // the failures left nothing to show.
            needsLoad = true
        }
        let isEmpty = movies.isEmpty && series.isEmpty && episodes.isEmpty
        filmographyStatus = if let firstError, isEmpty {
            .failed(firstError)
        } else {
            .loaded
        }

        // Person items rarely carry a backdrop of their own; borrow one from
        // the filmography. `backdropURL(for:)` handles backdrop → thumb →
        // ancestor fallbacks, so the filter matches what would actually render.
        backdropItem = (movies + series)
            .filter { client.backdropURL(for: $0) != nil }
            .randomElement()
    }

    /// Re-run the load now — the failed notice's Retry button.
    public func retry() async {
        needsLoad = true
        await load()
    }

    // MARK: - User-Data Actions

    /// Optimistically flip the favorite state, then persist; revert on
    /// failure. Person IDs are item IDs, so the standard favorite endpoints
    /// apply.
    public func toggleFavorite() async {
        guard let client, let member else { return }
        let target = !isFavorite
        favoriteOverride = target
        do {
            if target {
                try await client.markFavorite(itemId: member.id)
            } else {
                try await client.unmarkFavorite(itemId: member.id)
            }
        } catch {
            favoriteOverride = !target
        }
    }

    /// One filmography shelf, boxed as a `Result` so a throw doesn't discard
    /// its concurrently-fetched siblings.
    private nonisolated static func fetchFilmography(
        client: any JellyfinClientProtocol,
        personId: String,
        itemTypes: [MediaType],
    ) async -> Result<[MediaItem], Error> {
        do {
            return try await .success(client.getItemsFeaturingPerson(
                personId: personId, itemTypes: itemTypes, personTypes: nil, limit: shelfLimit,
            ))
        } catch {
            return .failure(error)
        }
    }
}

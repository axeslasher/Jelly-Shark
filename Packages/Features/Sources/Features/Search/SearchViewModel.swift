import Foundation
import JellyfinKit
import Observation

/// View model backing the search screen.
///
/// Owns the debounced query → results pipeline so the view stays declarative
/// and the search/cancellation logic is unit-testable.
@Observable
@MainActor
public final class SearchViewModel {
    /// The lifecycle of a search query.
    public enum State: Equatable {
        /// No active query (empty field).
        case idle
        /// A search is in flight.
        case searching
        /// The query returned no matches.
        case empty
        /// The query returned matches (held in the per-type shelves).
        case results
        /// The query failed; carries a user-facing message.
        case failed(String)
    }

    // MARK: - State

    /// The current search field text (two-way bound from the view).
    public var query: String = ""

    /// The latest search results, grouped by item type — one shelf each, in
    /// the order the screen renders them. Each is fetched by its own query so
    /// the per-type caps mean something: one mixed fetch truncated by an
    /// alphabetical sort can return forty A–C titles and no episodes at all,
    /// which would make the group sizes an artifact of the alphabet.
    public private(set) var movies: [MediaItem] = []
    public private(set) var series: [MediaItem] = []
    public private(set) var episodes: [MediaItem] = []

    /// Every result, flattened in shelf order — what the search-completion
    /// suggestions read.
    public var allResults: [MediaItem] {
        movies + series + episodes
    }

    /// The current query lifecycle state.
    public private(set) var state: State = .idle

    /// Library titles offered as a starting point while the field is empty.
    ///
    /// Empty until the fetch lands, and stays empty when the server errors or
    /// the library has nothing to offer — each of which leaves the empty state
    /// exactly as it looks without this feature.
    public private(set) var seedTerms: [MediaItem] = []

    // MARK: - Configuration

    /// How many titles to seed the empty state with. `jellyfin-web` asks for
    /// 20, which is a lot of text buttons at ten feet — and the empty state
    /// stacks them vertically under the glyph and copy, so this is bounded by
    /// what fits on screen without scrolling rather than by taste.
    private static let seedTermLimit = 5

    /// Maximum number of results to request *per shelf* — three queries go
    /// out per search, one per item type. Matches `PersonDetailViewModel`'s
    /// shelf limit: a few pages of horizontal scrolling without pagination.
    private let limit: Int

    /// Debounce delay before issuing a search after typing stops.
    private let debounce: Duration

    /// The authenticated client, attached by the view once available.
    private var client: (any JellyfinClientProtocol)?

    /// The in-flight (debounced) search task, retained so it can be cancelled.
    private var searchTask: Task<Void, Never>?

    /// The seed-terms fetch. Non-nil once started, and never reset — it is
    /// what makes the fetch once-per-lifetime rather than once-per-visit.
    private var seedTermsTask: Task<Void, Never>?

    public init(limit: Int = 25, debounce: Duration = .milliseconds(300)) {
        self.limit = limit
        self.debounce = debounce
    }

    // MARK: - Suggestions

    /// Term-completion suggestions derived from the current result titles.
    ///
    /// Mirrors the platform search pattern: as results come back, their unique
    /// names whose text matches the query become tappable completions.
    public var suggestions: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var seen = Set<String>()
        var ordered: [String] = []
        for name in allResults.map(\.name) where name.localizedCaseInsensitiveContains(trimmed) {
            if seen.insert(name).inserted {
                ordered.append(name)
            }
            if ordered.count == 8 {
                break
            }
        }
        return ordered
    }

    // MARK: - Actions

    /// Attach the authenticated client (called by the view when the session connects).
    ///
    /// The first attach that carries a client also kicks off the one and only
    /// seed-terms fetch. Later attaches that still carry a client — a tab
    /// revisit, a reconnect — swap the client but leave the terms alone: the
    /// query is randomised server-side, so refetching would reshuffle the list
    /// under a viewer who just cleared the field, which reads as instability
    /// rather than variety.
    ///
    /// A nil client means the session ended. Everything derived from the signed-in
    /// account is dropped and the fetch is re-armed, because this view model
    /// outlives the session: `SearchView` holds it in `@State` and `RootView`
    /// keeps the tab mounted across a disconnect, so without this the next
    /// account to sign in would be shown the previous account's library. Two
    /// Jellyfin users on one server do not necessarily see the same libraries.
    public func attach(client: (any JellyfinClientProtocol)?) {
        self.client = client

        guard let client else {
            resetForSignOut()
            return
        }

        guard seedTermsTask == nil else { return }
        seedTermsTask = Task { [weak self] in
            await self?.fetchSeedTerms(client: client)
        }
    }

    /// Drop every trace of the signed-out account and re-arm the seed fetch.
    private func resetForSignOut() {
        seedTermsTask?.cancel()
        seedTermsTask = nil
        seedTerms = []

        searchTask?.cancel()
        searchTask = nil
        clearResults()
        query = ""
        state = .idle
    }

    /// Empty every shelf. They clear together, always: a shelf missed here
    /// would show the previous account's titles to the next one.
    private func clearResults() {
        movies = []
        series = []
        episodes = []
    }

    /// React to a change in the search field.
    ///
    /// Cancels any in-flight search. An empty query resets to `.idle`; a
    /// non-empty query starts a debounced search.
    public func updateQuery(_ text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearResults()
            state = .idle
            return
        }

        state = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.performSearch(query: trimmed)
        }
    }

    /// Search for one of the seeded terms, as if the viewer had typed it.
    ///
    /// The field text is part of the affordance: the term lands in the search
    /// field, editable, rather than jumping straight to one item.
    public func selectSeedTerm(_ term: String) {
        query = term
        // The view's `onChange` on `query` will call this again a frame later
        // with the same text; `updateQuery` cancels the pending debounce and
        // reissues, so the server still sees exactly one search.
        updateQuery(term)
    }

    /// Awaits completion of the in-flight (debounced) search, if any.
    ///
    /// Intended for tests to observe results deterministically without sleeping.
    func awaitPendingSearch() async {
        await searchTask?.value
    }

    /// Awaits the seed-terms fetch, if one was started.
    ///
    /// Intended for tests to observe `seedTerms` deterministically without sleeping.
    func awaitPendingSeedTerms() async {
        await seedTermsTask?.value
    }

    private func fetchSeedTerms(client: any JellyfinClientProtocol) async {
        do {
            seedTerms = try await client.getSearchSuggestions(limit: Self.seedTermLimit)
        } catch {
            // Seeded terms are a nicety, not a feature the screen owes anyone.
            // A server that declines to answer gets the plain prompt — no
            // banner, no retry, no state to explain.
            seedTerms = []
        }
    }

    /// One round of searches: three concurrent per-type queries, combined with
    /// partial survival (the person page's filmography rule verbatim) —
    /// whatever came back renders, and `.failed` is reported only when the
    /// failures left nothing to show.
    private func performSearch(query: String) async {
        guard let client else {
            state = .failed(APIError.notAuthenticated.localizedDescription)
            return
        }

        async let moviesFetch = Self.fetchShelf(
            client: client, query: query, itemTypes: [.movie], limit: limit,
        )
        async let seriesFetch = Self.fetchShelf(
            client: client, query: query, itemTypes: [.series], limit: limit,
        )
        async let episodesFetch = Self.fetchShelf(
            client: client, query: query, itemTypes: [.episode], limit: limit,
        )

        let fetched = await [moviesFetch, seriesFetch, episodesFetch]
        guard !Task.isCancelled else { return }

        movies = (try? fetched[0].get()) ?? []
        series = (try? fetched[1].get()) ?? []
        episodes = (try? fetched[2].get()) ?? []

        let firstError = fetched.compactMap { result -> String? in
            if case let .failure(error) = result {
                return error.localizedDescription
            }
            return nil
        }.first

        let isEmpty = movies.isEmpty && series.isEmpty && episodes.isEmpty
        state = if let firstError, isEmpty {
            .failed(firstError)
        } else if isEmpty {
            .empty
        } else {
            .results
        }
    }

    /// One result shelf, boxed as a `Result` so a throw doesn't discard its
    /// concurrently-fetched siblings.
    private nonisolated static func fetchShelf(
        client: any JellyfinClientProtocol,
        query: String,
        itemTypes: [MediaType],
        limit: Int,
    ) async -> Result<[MediaItem], Error> {
        do {
            return try await .success(client.searchItems(
                query: query, itemTypes: itemTypes, limit: limit,
            ))
        } catch {
            return .failure(error)
        }
    }
}

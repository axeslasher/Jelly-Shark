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
        /// The query returned matches (held in `results`).
        case results
        /// The query failed; carries a user-facing message.
        case failed(String)
    }

    // MARK: - State

    /// The current search field text (two-way bound from the view).
    public var query: String = ""

    /// The latest search results.
    public private(set) var results: [MediaItem] = []

    /// The current query lifecycle state.
    public private(set) var state: State = .idle

    // MARK: - Configuration

    /// Maximum number of results to request.
    private let limit: Int

    /// Debounce delay before issuing a search after typing stops.
    private let debounce: Duration

    /// The authenticated client, attached by the view once available.
    private var client: (any JellyfinClientProtocol)?

    /// The in-flight (debounced) search task, retained so it can be cancelled.
    private var searchTask: Task<Void, Never>?

    public init(limit: Int = 40, debounce: Duration = .milliseconds(300)) {
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
        for name in results.map(\.name) where name.localizedCaseInsensitiveContains(trimmed) {
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
    public func attach(client: (any JellyfinClientProtocol)?) {
        self.client = client
    }

    /// React to a change in the search field.
    ///
    /// Cancels any in-flight search. An empty query resets to `.idle`; a
    /// non-empty query starts a debounced search.
    public func updateQuery(_ text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
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

    /// Awaits completion of the in-flight (debounced) search, if any.
    ///
    /// Intended for tests to observe results deterministically without sleeping.
    func awaitPendingSearch() async {
        await searchTask?.value
    }

    private func performSearch(query: String) async {
        guard let client else {
            state = .failed(APIError.notAuthenticated.localizedDescription)
            return
        }

        do {
            let items = try await client.searchItems(query: query, limit: limit)
            guard !Task.isCancelled else { return }
            results = items
            state = items.isEmpty ? .empty : .results
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            state = .failed(error.localizedDescription)
        }
    }
}

@testable import Features
import Foundation
import JellyfinKit
import Testing

@MainActor
struct SearchViewModelTests {
    private func makeViewModel(client: MockJellyfinClient) -> SearchViewModel {
        // Zero debounce keeps tests fast and deterministic; awaitPendingSearch()
        // still synchronizes on the search task itself.
        let viewModel = SearchViewModel(debounce: .zero)
        viewModel.attach(client: client)
        return viewModel
    }

    private func movie(_ id: String, _ name: String, year: Int? = nil) -> MediaItem {
        MediaItem(id: id, name: name, type: .movie, productionYear: year)
    }

    private func series(_ id: String, _ name: String) -> MediaItem {
        MediaItem(id: id, name: name, type: .series)
    }

    private func episode(_ id: String, _ name: String, series seriesName: String = "Show") -> MediaItem {
        MediaItem(id: id, name: name, type: .episode, seriesName: seriesName)
    }

    /// One search is now a *round* of exactly three queries for the same term,
    /// one per item type. Asserting the round (rather than "at least one call")
    /// keeps the original guarantee that a single press issues a single search.
    private func expectOneRound(_ client: MockJellyfinClient, for term: String) {
        #expect(client.searchQueries.count == 3)
        #expect(Set(client.searchQueries.map(\.query)) == [term])
        #expect(Set(client.searchQueries.map(\.itemTypes)) == [[.movie], [.series], [.episode]])
    }

    @Test("Empty query stays idle and never calls the client")
    func emptyQueryIsIdle() async {
        let client = MockJellyfinClient()
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("   ")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.state == .idle)
        #expect(viewModel.allResults.isEmpty)
        #expect(client.searchQueries.isEmpty)
    }

    @Test("A non-empty query runs one round of three and populates results")
    func queryPopulatesResults() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([movie("1", "Batman"), movie("2", "Batman Returns")])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()

        expectOneRound(client, for: "bat")
        #expect(viewModel.movies.count == 2)
        #expect(viewModel.state == .results)
    }

    @Test("Results are grouped into their own shelves, in section order")
    func groupsResultsByType() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([
            movie("1", "Batman"),
            series("2", "Batman: The Animated Series"),
            episode("3", "Nothing to Fear", series: "Batman: The Animated Series"),
            movie("4", "Batman Returns"),
        ])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("batman")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.movies.map(\.id) == ["1", "4"])
        #expect(viewModel.series.map(\.id) == ["2"])
        #expect(viewModel.episodes.map(\.id) == ["3"])
        // The flat accessor the suggestions read follows the shelf order.
        #expect(viewModel.allResults.map(\.id) == ["1", "4", "2", "3"])
        #expect(viewModel.state == .results)
    }

    @Test("A type with no matches leaves its shelf empty, the others populated")
    func typeWithNoMatchesIsEmptyShelf() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([movie("1", "Batman"), movie("2", "Batman Returns")])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("batman")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.movies.count == 2)
        #expect(viewModel.series.isEmpty)
        #expect(viewModel.episodes.isEmpty)
        // Still `.results` — an empty shelf renders nothing, it isn't an
        // empty *search*.
        #expect(viewModel.state == .results)
    }

    @Test("Zero matches in every type yields the empty state")
    func zeroMatchesIsEmpty() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("zzz")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.state == .empty)
        #expect(viewModel.allResults.isEmpty)
    }

    @Test("Every fetch throwing yields the failed state")
    func errorYieldsFailed() async {
        let client = MockJellyfinClient()
        client.searchResult = .failure(APIError.notAuthenticated)
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("oops")
        await viewModel.awaitPendingSearch()

        if case .failed = viewModel.state {
            // expected
        } else {
            Issue.record("Expected .failed, got \(viewModel.state)")
        }
        #expect(viewModel.allResults.isEmpty)
    }

    @Test("One type failing renders the survivors and stays in results")
    func partialFailureKeepsSurvivors() async {
        let client = MockJellyfinClient()
        client.searchHandler = { itemTypes in
            if itemTypes.contains(.series) {
                return .failure(APIError.generic("Series shelf failed"))
            }
            return .success(itemTypes.contains(.movie) ? [self.movie("1", "Alien")] : [])
        }
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("alien")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.movies.map(\.id) == ["1"])
        #expect(viewModel.series.isEmpty)
        #expect(viewModel.state == .results)
    }

    @Test("A failure that left nothing to show is the failed state")
    func totalFailureIsFailed() async {
        let client = MockJellyfinClient()
        client.searchHandler = { itemTypes in
            itemTypes.contains(.movie)
                ? .failure(APIError.generic("Movie shelf failed"))
                : .success([])
        }
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("alien")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.state == .failed(APIError.generic("Movie shelf failed").localizedDescription))
        #expect(viewModel.allResults.isEmpty)
    }

    @Test("Clearing the query resets to idle and empties every shelf")
    func clearingResetsToIdle() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([movie("1", "Batman"), series("2", "Batman Beyond")])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()
        #expect(viewModel.state == .results)

        viewModel.updateQuery("")
        #expect(viewModel.state == .idle)
        #expect(viewModel.movies.isEmpty)
        #expect(viewModel.series.isEmpty)
        #expect(viewModel.episodes.isEmpty)
    }

    @Test("Suggestions are unique title completions matching the query")
    func suggestionsAreMatchingTitles() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([
            movie("1", "Batman"),
            movie("2", "Batman"), // duplicate name -> deduped
            movie("3", "Batman Returns"),
            movie("4", "Superman"), // no match -> excluded
        ])
        let viewModel = makeViewModel(client: client)
        viewModel.query = "bat"

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.suggestions == ["Batman", "Batman Returns"])
    }

    // MARK: - Seed terms

    @Test("Attaching a client fetches the seed terms once")
    func attachFetchesSeedTerms() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([movie("1", "Alien"), movie("2", "Aliens")])
        let viewModel = makeViewModel(client: client)

        await viewModel.awaitPendingSeedTerms()

        #expect(client.searchSuggestionsCallCount == 1)
        #expect(viewModel.seedTerms.map(\.name) == ["Alien", "Aliens"])
    }

    @Test("A second attach does not refetch the seed terms")
    func secondAttachDoesNotRefetch() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([movie("1", "Alien")])
        let viewModel = makeViewModel(client: client)
        await viewModel.awaitPendingSeedTerms()

        // A tab revisit, or the session reconnecting: same client, same terms
        viewModel.attach(client: client)
        await viewModel.awaitPendingSeedTerms()

        #expect(client.searchSuggestionsCallCount == 1)
        #expect(viewModel.seedTerms.map(\.name) == ["Alien"])
    }

    @Test("Attaching without a client leaves the fetch for the real one")
    func attachWithoutClientDefersFetch() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([movie("1", "Alien")])
        let viewModel = SearchViewModel(debounce: .zero)

        // What the view does on first appear, before the session connects
        viewModel.attach(client: nil)
        await viewModel.awaitPendingSeedTerms()
        #expect(client.searchSuggestionsCallCount == 0)
        #expect(viewModel.seedTerms.isEmpty)

        viewModel.attach(client: client)
        await viewModel.awaitPendingSeedTerms()

        #expect(client.searchSuggestionsCallCount == 1)
        #expect(viewModel.seedTerms.map(\.name) == ["Alien"])
    }

    // MARK: - Sign-out

    @Test("Signing out drops the previous account's seed terms and refetches for the next")
    func signOutClearsSeedTermsAcrossAccounts() async {
        let first = MockJellyfinClient()
        first.searchSuggestionsResult = .success([movie("1", "Alien")])
        let viewModel = makeViewModel(client: first)
        await viewModel.awaitPendingSeedTerms()
        #expect(viewModel.seedTerms.map(\.name) == ["Alien"])

        // The view model outlives the session: SearchView holds it in @State and
        // RootView keeps the tab mounted across a disconnect. A second account
        // must never be shown the first account's library.
        viewModel.attach(client: nil)
        #expect(viewModel.seedTerms.isEmpty)

        let second = MockJellyfinClient()
        second.searchSuggestionsResult = .success([movie("2", "Solaris")])
        viewModel.attach(client: second)
        await viewModel.awaitPendingSeedTerms()

        #expect(second.searchSuggestionsCallCount == 1)
        #expect(viewModel.seedTerms.map(\.name) == ["Solaris"])
    }

    @Test("Signing out clears the query and every result shelf")
    func signOutClearsQueryAndResults() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([
            movie("1", "Alien"),
            series("2", "Alien Nation"),
            episode("3", "Pilot", series: "Alien Nation"),
        ])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("ali")
        await viewModel.awaitPendingSearch()
        #expect(viewModel.state == .results)
        #expect(viewModel.allResults.count == 3)

        viewModel.attach(client: nil)

        #expect(viewModel.query.isEmpty)
        // Each shelf individually: a missed array here would show the previous
        // account's titles to the next one.
        #expect(viewModel.movies.isEmpty)
        #expect(viewModel.series.isEmpty)
        #expect(viewModel.episodes.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test("A failed seed-terms fetch leaves the terms empty and the state idle")
    func seedTermsErrorIsSilent() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .failure(APIError.notAuthenticated)
        let viewModel = makeViewModel(client: client)

        await viewModel.awaitPendingSeedTerms()

        #expect(viewModel.seedTerms.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test("An empty seed-terms response leaves the terms empty")
    func seedTermsEmptyResponse() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([])
        let viewModel = makeViewModel(client: client)

        await viewModel.awaitPendingSeedTerms()

        #expect(viewModel.seedTerms.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test("Selecting a seed term fills the field and runs one round of searches")
    func selectingSeedTermRunsSearch() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([movie("1", "Alien")])
        client.searchResult = .success([movie("1", "Alien"), movie("2", "Aliens")])
        let viewModel = makeViewModel(client: client)
        await viewModel.awaitPendingSeedTerms()

        viewModel.selectSeedTerm("Alien")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.query == "Alien")
        // One press, one round — `selectSeedTerm` and the view's `onChange`
        // both call `updateQuery`, and the second must cancel the first rather
        // than issue a second round.
        expectOneRound(client, for: "Alien")
        #expect(viewModel.state == .results)
    }

    @Test("Seed terms do not leak into the query-completion suggestions")
    func seedTermsAreNotCompletions() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([movie("1", "Alien")])
        let viewModel = makeViewModel(client: client)
        await viewModel.awaitPendingSeedTerms()

        // The two lists are mutually exclusive by construction: completions
        // need a non-empty query, the seeded terms only show while it is empty.
        #expect(viewModel.suggestions.isEmpty)
        #expect(!viewModel.seedTerms.isEmpty)
    }

    @Test("Without a client, a query fails gracefully")
    func missingClientFails() async {
        let viewModel = SearchViewModel(debounce: .zero)

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()

        if case .failed = viewModel.state {
            // expected
        } else {
            Issue.record("Expected .failed, got \(viewModel.state)")
        }
    }
}

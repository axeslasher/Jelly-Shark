@testable import Features
import Foundation
import JellyfinKit
import Testing

@MainActor
struct SearchViewModelTests {
    private func makeViewModel(client: MockJellyfinClient) -> SearchViewModel {
        // Zero debounce keeps tests fast and deterministic; awaitPendingSearch()
        // still synchronizes on the search task itself.
        let viewModel = SearchViewModel(limit: 40, debounce: .zero)
        viewModel.attach(client: client)
        return viewModel
    }

    private func movie(_ id: String, _ name: String, year: Int? = nil) -> MediaItem {
        MediaItem(id: id, name: name, type: .movie, productionYear: year)
    }

    @Test("Empty query stays idle and never calls the client")
    func emptyQueryIsIdle() async {
        let client = MockJellyfinClient()
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("   ")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
        #expect(client.searchQueries.isEmpty)
    }

    @Test("A non-empty query populates results")
    func queryPopulatesResults() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([movie("1", "Batman"), movie("2", "Batman Returns")])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()

        #expect(client.searchQueries == ["bat"])
        #expect(viewModel.results.count == 2)
        #expect(viewModel.state == .results)
    }

    @Test("Zero matches yields the empty state")
    func zeroMatchesIsEmpty() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("zzz")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.state == .empty)
        #expect(viewModel.results.isEmpty)
    }

    @Test("A thrown error yields the failed state")
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
        #expect(viewModel.results.isEmpty)
    }

    @Test("Clearing the query resets to idle")
    func clearingResetsToIdle() async {
        let client = MockJellyfinClient()
        client.searchResult = .success([movie("1", "Batman")])
        let viewModel = makeViewModel(client: client)

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()
        #expect(viewModel.state == .results)

        viewModel.updateQuery("")
        #expect(viewModel.state == .idle)
        #expect(viewModel.results.isEmpty)
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
        let viewModel = SearchViewModel(limit: 40, debounce: .zero)

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

    @Test("Selecting a seed term fills the field and runs one search")
    func selectingSeedTermRunsSearch() async {
        let client = MockJellyfinClient()
        client.searchSuggestionsResult = .success([movie("1", "Alien")])
        client.searchResult = .success([movie("1", "Alien"), movie("2", "Aliens")])
        let viewModel = makeViewModel(client: client)
        await viewModel.awaitPendingSeedTerms()

        viewModel.selectSeedTerm("Alien")
        await viewModel.awaitPendingSearch()

        #expect(viewModel.query == "Alien")
        #expect(client.searchQueries == ["Alien"])
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
        let viewModel = SearchViewModel(limit: 40, debounce: .zero)

        viewModel.updateQuery("bat")
        await viewModel.awaitPendingSearch()

        if case .failed = viewModel.state {
            // expected
        } else {
            Issue.record("Expected .failed, got \(viewModel.state)")
        }
    }
}

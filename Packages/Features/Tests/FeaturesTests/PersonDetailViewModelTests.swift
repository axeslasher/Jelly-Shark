@testable import Features
import Foundation
import JellyfinKit
import Testing

@Suite("PersonDetailViewModel")
@MainActor
struct PersonDetailViewModelTests {
    /// A real server id (the adapter's fallback ids are "person-N", which
    /// `hasServerId` rejects).
    private static let member = CastMember(id: "guid-1", name: "Jane Doe", kind: "Actor")

    private func movie(_ id: String, backdrop: Bool = false) -> MediaItem {
        MediaItem(id: id, name: id, type: .movie, imageTags: backdrop ? ImageTags(backdrop: "tag") : nil)
    }

    private func series(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .series)
    }

    private func episode(_ id: String) -> MediaItem {
        MediaItem(id: id, name: id, type: .episode, seriesId: "s1")
    }

    /// Attach + load in one step, mirroring the view's `.task`.
    private func load(
        _ viewModel: PersonDetailViewModel,
        client: MockJellyfinClient?,
        member: CastMember = PersonDetailViewModelTests.member,
    ) async {
        viewModel.attach(client: client, member: member)
        await viewModel.load()
    }

    // MARK: - Full load

    @Test("All three shelves load, and the backdrop borrows from the filmography")
    func fullLoad() async {
        let client = MockJellyfinClient()
        client.itemsFeaturingPersonHandler = { [self] itemTypes in
            switch itemTypes {
            case [.movie]: .success([movie("m1", backdrop: true)])
            case [.series]: .success([series("s1")])
            case [.episode]: .success([episode("e1")])
            default: .success([])
            }
        }

        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.filmographyStatus == .loaded)
        #expect(viewModel.movies.map(\.id) == ["m1"])
        #expect(viewModel.series.map(\.id) == ["s1"])
        #expect(viewModel.episodes.map(\.id) == ["e1"])
        // The only backdrop-bearing entry is m1, so the borrow is deterministic.
        #expect(viewModel.backdropItem?.id == "m1")
        #expect(viewModel.person?.id == "person-id")
    }

    // MARK: - Failure

    @Test("Every shelf failing reports .failed and Retry recovers")
    func allFailedRetries() async {
        let client = MockJellyfinClient()
        client.itemsFeaturingPersonHandler = { _ in .failure(APIError.networkError("offline")) }

        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.filmographyStatus.isFailed)
        #expect(viewModel.movies.isEmpty)

        client.itemsFeaturingPersonHandler = { [self] itemTypes in
            itemTypes == [.movie] ? .success([movie("m1")]) : .success([])
        }
        await viewModel.retry()

        #expect(viewModel.filmographyStatus == .loaded)
        #expect(viewModel.movies.map(\.id) == ["m1"])
    }

    @Test("A partial failure shows what survived and re-arms the next load")
    func partialFailureRearms() async {
        let client = MockJellyfinClient()
        client.itemsFeaturingPersonHandler = { [self] itemTypes in
            switch itemTypes {
            case [.movie]: .failure(APIError.networkError("offline"))
            case [.series]: .success([series("s1")])
            default: .success([])
            }
        }

        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: client)

        // Something survived, so no error notice — but the gap re-armed a
        // reload for the next appearance.
        #expect(viewModel.filmographyStatus == .loaded)
        #expect(viewModel.movies.isEmpty)
        #expect(viewModel.series.map(\.id) == ["s1"])

        client.itemsFeaturingPersonHandler = { [self] itemTypes in
            switch itemTypes {
            case [.movie]: .success([movie("m1")])
            case [.series]: .success([series("s1")])
            default: .success([])
            }
        }
        await load(viewModel, client: client)

        #expect(viewModel.movies.map(\.id) == ["m1"])
    }

    @Test("A failed person fetch alone is enrichment — the page still loads")
    func personFailureIsEnrichment() async {
        let client = MockJellyfinClient()
        client.personResult = .failure(APIError.networkError("offline"))
        client.itemsFeaturingPersonHandler = { [self] itemTypes in
            itemTypes == [.movie] ? .success([movie("m1")]) : .success([])
        }

        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: client)

        #expect(viewModel.filmographyStatus == .loaded)
        #expect(viewModel.person == nil)
        #expect(viewModel.movies.map(\.id) == ["m1"])
    }

    // MARK: - Edge cases

    @Test("A member without a server id fetches nothing and isn't an error")
    func noServerIdLoadsNothing() async {
        let client = MockJellyfinClient()
        let stub = CastMember(id: "person-3", name: "Uncredited", kind: "Actor")

        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: client, member: stub)

        #expect(viewModel.filmographyStatus == .loaded)
        #expect(client.itemsFeaturingPersonRequests.isEmpty)
    }

    @Test("A nil client parks at .loading — the stub header keeps rendering")
    func nilClientStaysLoading() async {
        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: nil)

        #expect(viewModel.filmographyStatus == .loading)
    }

    @Test("Loads once per person; a reappearance is a no-op")
    func loadOncePerPerson() async {
        let client = MockJellyfinClient()

        let viewModel = PersonDetailViewModel()
        await load(viewModel, client: client)
        let requestCount = client.itemsFeaturingPersonRequests.count

        await load(viewModel, client: client)
        #expect(client.itemsFeaturingPersonRequests.count == requestCount)
    }
}

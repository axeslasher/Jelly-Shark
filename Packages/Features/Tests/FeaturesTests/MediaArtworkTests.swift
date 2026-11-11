@testable import Features
import Foundation
import JellyfinKit
import Testing

/// Every artwork helper must put the tag of the image it chose on the URL:
/// the server only grants a cache lifetime to tagged requests (#117).
@Suite("MediaArtwork tags")
@MainActor
struct MediaArtworkTests {
    private let client = MockJellyfinClient()

    private func tag(of url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "tag" }?.value
    }

    @Test("Own artwork carries its own tag")
    func ownArtwork() {
        let item = MediaItem(
            id: "m1",
            name: "Movie",
            type: .movie,
            imageTags: ImageTags(primary: "p", backdrop: "b", thumb: "t", logo: "l"),
        )
        #expect(tag(of: client.posterURL(for: item)) == "p")
        #expect(tag(of: client.backdropURL(for: item)) == "b")
        #expect(tag(of: client.landscapeURL(for: item)) == "t")
        #expect(tag(of: client.logoURL(for: item)) == "l")
        #expect(client.backdropSlot(for: item)?.tag == "b")
    }

    @Test("A fallback carries the tag of the image it fell back to")
    func fallbacks() {
        let item = MediaItem(
            id: "m1",
            name: "Movie",
            type: .movie,
            imageTags: ImageTags(thumb: "t"),
        )
        #expect(tag(of: client.posterURL(for: item)) == "t")
        #expect(tag(of: client.backdropURL(for: item)) == "t")
    }

    @Test("Inherited artwork carries the ancestor's tag")
    func inheritedArtwork() {
        let episode = MediaItem(
            id: "e1",
            name: "Episode",
            type: .episode,
            seriesId: "s1",
            parentArtwork: ParentArtwork(
                backdropItemId: "s1",
                backdropImageTag: "sb",
                logoItemId: "s1",
                logoImageTag: "sl",
                seriesPrimaryImageTag: "sp",
            ),
        )
        #expect(client.posterURL(for: episode)?.path() == "/Items/s1/Images/Primary")
        #expect(tag(of: client.posterURL(for: episode)) == "sp")
        #expect(tag(of: client.backdropURL(for: episode)) == "sb")
        #expect(tag(of: client.logoURL(for: episode)) == "sl")
    }

    @Test("Library and headshot artwork carry their primary tag")
    func libraryAndHeadshot() {
        let library = Library(id: "lib", name: "Movies", primaryImageTag: "lp")
        let member = CastMember(id: "p1", name: "Actor", kind: "Actor", primaryImageTag: "hp")
        #expect(tag(of: client.imageURL(for: library)) == "lp")
        #expect(tag(of: client.headshotURL(for: member)) == "hp")
    }
}

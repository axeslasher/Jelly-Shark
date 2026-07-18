import Foundation
import JellyfinAPI
@testable import JellyfinKit
import Testing

/// The SDK ships its own `JellyfinAPI.JellyfinClient`; in this file the
/// client under test is always the domain one
private typealias JellyfinClient = JellyfinKit.JellyfinClient

@Suite("Chapter adapters")
struct ChapterAdapterTests {
    private func dto(
        name: String? = "The Beginning",
        startTicks: Int? = 0,
        imageTag: String? = "tag-1",
    ) -> JellyfinAPI.ChapterInfo {
        JellyfinAPI.ChapterInfo(
            imageTag: imageTag,
            name: name,
            startPositionTicks: startTicks,
        )
    }

    @Test("DTO fields map onto the domain type")
    func fieldMapping() throws {
        let chapter = try #require(Chapter(from: dto(startTicks: 6_000_000_000), index: 2))
        #expect(chapter.name == "The Beginning")
        #expect(chapter.startTicks == 6_000_000_000)
        #expect(chapter.imageIndex == 2)
        #expect(chapter.imageTag == "tag-1")
        #expect(chapter.startSeconds == 600)
    }

    @Test("Missing or negative start positions drop the entry")
    func rejectsUnpositionedChapters() {
        #expect(Chapter(from: dto(startTicks: nil), index: 0) == nil)
        #expect(Chapter(from: dto(startTicks: -1), index: 0) == nil)
    }

    @Test("A missing or blank name falls back to the 1-based chapter number")
    func nameFallback() {
        #expect(Chapter(from: dto(name: nil), index: 0)?.name == "Chapter 1")
        #expect(Chapter(from: dto(name: ""), index: 4)?.name == "Chapter 5")
        #expect(Chapter(from: dto(name: "  \n"), index: 9)?.name == "Chapter 10")
    }

    @Test("Array mapping preserves original server indices across drops")
    func indexPreservation() {
        let chapters = Chapter.chapters(from: [
            dto(name: "One"),
            dto(name: "Broken", startTicks: nil),
            dto(name: nil, startTicks: 12_000_000_000, imageTag: nil),
        ])

        #expect(chapters.count == 2)
        #expect(chapters[0].imageIndex == 0)
        // The survivor after the dropped sibling keeps server index 2
        #expect(chapters[1].imageIndex == 2)
        #expect(chapters[1].name == "Chapter 3")
        #expect(chapters[1].imageTag == nil)
    }

    @Test("An empty server array maps to no chapters")
    func emptyChapters() {
        #expect(Chapter.chapters(from: []).isEmpty)
    }
}

@Suite("Chapter image URLs")
struct ChapterImageURLTests {
    private func queryItems(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        )
    }

    private func makeClient(serverURL: String) -> JellyfinClient {
        JellyfinClient(configuration: JellyfinClientConfiguration(serverURL: URL(string: serverURL)!))
    }

    @Test("Chapter image URL targets the indexed chapter endpoint")
    func chapterImageURL() {
        let url = makeClient(serverURL: "https://example.com")
            .chapterImageURL(itemId: "item-1", chapterIndex: 3, tag: "tag-abc", maxWidth: 320)

        #expect(url.path == "/Items/item-1/Images/Chapter/3")
        let query = queryItems(of: url)
        #expect(query["tag"] == "tag-abc")
        #expect(query["maxWidth"] == "320")
    }

    @Test("Chapter image URL omits maxWidth when nil and keeps a path prefix")
    func chapterImageURLPathPrefix() {
        let url = makeClient(serverURL: "https://example.com/jellyfin")
            .chapterImageURL(itemId: "item-1", chapterIndex: 0, tag: "t", maxWidth: nil)

        #expect(url.path == "/jellyfin/Items/item-1/Images/Chapter/0")
        #expect(queryItems(of: url)["maxWidth"] == nil)
    }
}

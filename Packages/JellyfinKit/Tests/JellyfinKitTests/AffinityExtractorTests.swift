import Foundation
@testable import JellyfinKit
import Testing

@Suite("AffinityExtractor")
struct AffinityExtractorTests {
    private func item(
        id: String = "i1",
        genres: [String]? = nil,
        year: Int? = nil,
        people: [CastMember]? = nil,
    ) -> MediaItem {
        MediaItem(id: id, name: "Item \(id)", type: .movie, productionYear: year, genres: genres, people: people)
    }

    @Test func genreAndDecadeBucketsComeFromGenresAndYear() {
        let buckets = AffinityExtractor.buckets(
            for: item(genres: ["Horror", "Thriller"], year: 1987),
            favoritedPersonIDs: [],
        )
        #expect(buckets.contains(.genre("Horror")))
        #expect(buckets.contains(.genre("Thriller")))
        #expect(buckets.contains(.genreDecade("Horror", 1980)))
        #expect(buckets.contains(.genreDecade("Thriller", 1980)))
    }

    @Test func noYearMeansNoDecadeBuckets() {
        let buckets = AffinityExtractor.buckets(for: item(genres: ["Horror"], year: nil), favoritedPersonIDs: [])
        #expect(buckets == [.genre("Horror")])
    }

    @Test func onlyDirectorAndWriterCreditsMintPersonBuckets() {
        let people = [
            CastMember(id: "p-dir", name: "Dir", kind: "Director"),
            CastMember(id: "p-wri", name: "Wri", kind: "Writer"),
            CastMember(id: "p-act", name: "Act", kind: "Actor"),
        ]
        let buckets = AffinityExtractor.buckets(for: item(people: people), favoritedPersonIDs: [])
        #expect(buckets.contains(.person("p-dir")))
        #expect(buckets.contains(.person("p-wri")))
        #expect(!buckets.contains(.person("p-act")))
    }

    /// Spec § 4.2 rule 1, second clause: favoriting a person unlocks their credits.
    @Test func favoritingAPersonUnlocksTheirIneligibleCredits() {
        let people = [CastMember(id: "p-act", name: "Act", kind: "Actor")]
        let buckets = AffinityExtractor.buckets(for: item(people: people), favoritedPersonIDs: ["p-act"])
        #expect(buckets.contains(.person("p-act")))
    }

    @Test func fallbackPersonIdsNeverMintABucket() {
        let people = [CastMember(id: "person-3", name: "Nameless", kind: "Director")]
        let buckets = AffinityExtractor.buckets(for: item(people: people), favoritedPersonIDs: ["person-3"])
        #expect(buckets.isEmpty)
    }

    @Test func personNamesAreCarriedForEveryMintedPersonBucket() {
        let people = [CastMember(id: "p-dir", name: "Ada", kind: "Director")]
        let names = AffinityExtractor.personNames(for: item(people: people), favoritedPersonIDs: [])
        #expect(names == ["p-dir": "Ada"])
    }

    @Test func identityIsUniqueAcrossKinds() {
        #expect(AffinityBucket.genre("Horror").identity == "genre|Horror")
        #expect(AffinityBucket.genreDecade("Horror", 1980).identity == "genreDecade|Horror|1980")
        #expect(AffinityBucket.person("p1").identity == "person|p1")
    }
}

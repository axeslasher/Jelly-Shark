import Foundation
@testable import JellyfinKit
import Testing

@Suite("Search relevance ordering")
struct SearchRelevanceTests {
    private func item(_ name: String, originalTitle: String? = nil) -> MediaItem {
        MediaItem(id: name, name: name, originalTitle: originalTitle, type: .movie)
    }

    private func names(_ items: [MediaItem]) -> [String] {
        items.map(\.name)
    }

    @Suite("Match tiers")
    struct MatchTierTests {
        private func tier(_ title: String, _ query: String) -> SearchRelevance.MatchTier {
            SearchRelevance.tier(title: title, normalizedQuery: SearchRelevance.normalized(query))
        }

        @Test("The whole title matching the query is the best tier")
        func exact() {
            #expect(tier("Batman", "batman") == .exact)
            #expect(tier("BATMAN", "Batman") == .exact)
            #expect(tier(" Batman ", "batman") == .exact)
        }

        @Test("A title starting with the query beats one containing it later")
        func prefixBeatsWordPrefix() {
            #expect(tier("Batman Begins", "batman") == .prefix)
            #expect(tier("The Batman", "batman") == .wordPrefix)
            #expect(SearchRelevance.MatchTier.prefix < SearchRelevance.MatchTier.wordPrefix)
        }

        @Test("A word starting with the query beats a mid-word match")
        func wordPrefixBeatsContains() {
            #expect(tier("The Man Who Fell to Earth", "man") == .wordPrefix)
            #expect(tier("Batman", "man") == .contains)
        }

        @Test("A later word start wins even when an earlier match sat mid-word")
        func laterWordStartCounts() {
            // "star" is mid-word in "Rockstar", then starts a word in "Star Trek"
            #expect(tier("Rockstar Star Trek", "star") == .wordPrefix)
        }

        @Test("A title merely beginning with the query's letters is still a prefix match")
        func prefixIsNotWordAware() {
            // Matches the server's own ladder, which scores a bare StartsWith.
            #expect(tier("Batmanic Adventures", "batman") == .prefix)
        }

        @Test("Punctuation and colons count as word boundaries")
        func punctuationIsABoundary() {
            #expect(tier("Aliens: Special Edition", "special") == .wordPrefix)
        }

        @Test("Diacritics do not change the tier")
        func diacriticInsensitive() {
            #expect(tier("Amélie", "amelie") == .exact)
            #expect(tier("Amelie", "amélie") == .exact)
        }

        @Test("A title the query does not appear in is the last tier")
        func noMatch() {
            #expect(tier("Heat", "batman") == .none)
            #expect(tier("", "batman") == .none)
            #expect(tier("Batman", "") == .none)
        }
    }

    @Test("An exact match surfaces first, ahead of alphabetically earlier matches")
    func exactMatchWins() {
        // Server order: alphabetical, which is what puts Batman & Robin first.
        let ranked = SearchRelevance.ranked(
            [item("Batman & Robin"), item("Batman"), item("Batman Begins"), item("The Batman")],
            matching: "batman",
        )

        #expect(names(ranked) == ["Batman", "Batman & Robin", "Batman Begins", "The Batman"])
    }

    @Test("Title prefix, then word prefix, then mid-word")
    func tiersOrderTheResults() {
        let ranked = SearchRelevance.ranked(
            [item("Rockstar"), item("Star Trek"), item("The Star Chamber")],
            matching: "star",
        )

        #expect(names(ranked) == ["Star Trek", "The Star Chamber", "Rockstar"])
    }

    @Test("Alphabetical order survives inside a tier")
    func stableWithinATier() {
        let ranked = SearchRelevance.ranked(
            [item("Star Trek"), item("Star Wars"), item("Stargate")],
            matching: "star",
        )

        // All three are prefix matches, so the incoming (server) order stands.
        #expect(names(ranked) == ["Star Trek", "Star Wars", "Stargate"])
    }

    @Test("A match on the original title ranks as well as one on the display name")
    func originalTitleCounts() {
        let ranked = SearchRelevance.ranked(
            [
                item("A Documentary About Le Salaire de la Peur"),
                item("The Wages of Fear", originalTitle: "Le salaire de la peur"),
            ],
            matching: "le salaire de la peur",
        )

        #expect(names(ranked) == ["The Wages of Fear", "A Documentary About Le Salaire de la Peur"])
    }

    @Test("Items the query does not appear in are kept, at the end")
    func unmatchedItemsSurvive() {
        // The server matches on fields this ranking cannot see; nothing it
        // returned may be silently dropped.
        let ranked = SearchRelevance.ranked([item("Heat"), item("Batman")], matching: "batman")

        #expect(names(ranked) == ["Batman", "Heat"])
    }

    @Test("An empty query leaves the server order alone")
    func emptyQueryIsAPassthrough() {
        let items = [item("Batman"), item("Alien")]

        #expect(names(SearchRelevance.ranked(items, matching: "   ")) == ["Batman", "Alien"])
    }

    @Suite("Fetch window")
    struct FetchWindowTests {
        @Test("The window is wider than the caller's limit so ranking has candidates")
        func widerThanLimit() {
            #expect(SearchRelevance.fetchWindow(for: 25) == 100)
        }

        @Test("The window is capped so a broad query cannot balloon the payload")
        func capped() {
            #expect(SearchRelevance.fetchWindow(for: 500) == SearchRelevance.maxFetchWindow)
        }

        @Test("An unlimited fetch needs no window")
        func unlimited() {
            #expect(SearchRelevance.fetchWindow(for: nil) == nil)
        }
    }
}

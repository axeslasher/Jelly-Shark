import DesignSystem
@testable import Features
import Testing

@Suite("HomeFocusReconciler")
struct HomeFocusReconcilerTests {
    private func rows(_ raw: [(String, [String])]) -> [HomeFocusReconciler.Row] {
        raw.map { HomeFocusReconciler.Row(id: $0.0, itemIDs: $0.1) }
    }

    @Test func prefersTheSiblingAtTheLowerIndex() {
        // Cards to the right shift left into the gap, so the left
        // neighbour is the one that stayed put under the viewer's eye.
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a", "b", "c"]), ("latest", ["d"])]),
            after: rows([("continue", ["a", "c"]), ("latest", ["d"])]),
            vanished: ShelfFocusID(row: "continue", item: "b"),
        )
        #expect(next == ShelfFocusID(row: "continue", item: "a"))
    }

    @Test func fallsForwardWhenTheVanishedCardWasFirst() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a", "b"]), ("latest", ["d"])]),
            after: rows([("continue", ["b"]), ("latest", ["d"])]),
            vanished: ShelfFocusID(row: "continue", item: "a"),
        )
        #expect(next == ShelfFocusID(row: "continue", item: "b"))
    }

    @Test func movesToTheNextRowDownWhenTheRowEmptied() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"]), ("latest", ["d", "e"])]),
            after: rows([("continue", []), ("latest", ["d", "e"])]),
            vanished: ShelfFocusID(row: "continue", item: "a"),
        )
        #expect(next == ShelfFocusID(row: "latest", item: "d"))
    }

    @Test func aRemovedRowDoesNotLetTheRowBelowInheritItsIndex() {
        // "latest-movies" is gone entirely, so "genres" now sits at index
        // 1. Resolving by index would call that the same row and pick its
        // index-0 card as a *sibling*; it is a different row, so the rule
        // is "first card of the next row down" — which happens to agree
        // here, but must agree for the right reason. The distinguishing
        // case is the one below.
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"]), ("latest-movies", ["m1", "m2"]), ("genres", ["g1", "g2"])]),
            after: rows([("continue", ["a"]), ("genres", ["g1", "g2"])]),
            vanished: ShelfFocusID(row: "latest-movies", item: "m2"),
        )
        // Index-based logic would have returned g2 (index 1 of the row
        // that moved up). The row is gone, so focus goes to the first
        // card of the next surviving row.
        #expect(next == ShelfFocusID(row: "genres", item: "g1"))
    }

    @Test func skipsAnEmptyRowOnTheWayDown() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"]), ("latest", ["d"]), ("genres", ["g"])]),
            after: rows([("continue", []), ("latest", []), ("genres", ["g"])]),
            vanished: ShelfFocusID(row: "continue", item: "a"),
        )
        // Genre rows are rows too — jumping to the hero past a populated
        // one throws the viewer to the top of the page for no reason.
        #expect(next == ShelfFocusID(row: "genres", item: "g"))
    }

    @Test func movesToTheRowAboveWhenNoRowRemainsBelow() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a", "b"]), ("latest", ["d"])]),
            after: rows([("continue", ["a", "b"]), ("latest", [])]),
            vanished: ShelfFocusID(row: "latest", item: "d"),
        )
        #expect(next == ShelfFocusID(row: "continue", item: "a"))
    }

    @Test func returnsNilWhenNothingIsLeftToFocus() {
        // nil means the hero — never a silent jump with nowhere stated.
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"]), ("latest", ["d"])]),
            after: rows([("continue", []), ("latest", [])]),
            vanished: ShelfFocusID(row: "continue", item: "a"),
        )
        #expect(next == nil)
    }

    @Test func returnsNilWhenTheVanishedRowIsUnknown() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"])]),
            after: rows([("continue", ["a"])]),
            vanished: ShelfFocusID(row: "ghost", item: "x"),
        )
        #expect(next == nil)
    }
}

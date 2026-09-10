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
        // index-2 card as a *sibling*; it is a different row. The row above
        // still exists and never moves, so focus goes there.
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"]), ("latest-movies", ["m1", "m2", "m3"]), ("genres", ["g1", "g2", "g3"])]),
            after: rows([("continue", ["a"]), ("genres", ["g1", "g2", "g3"])]),
            vanished: ShelfFocusID(row: "latest-movies", item: "m3"),
        )
        // Index-based logic would have returned g3; next-row-down would
        // have returned g1, a card still sliding up into the gap when the
        // reveal scroll runs.
        #expect(next == ShelfFocusID(row: "continue", item: "a"))
    }

    @Test func aMiddleRowVanishingLandsOnTheRowAboveNotBelow() {
        // The row above is the one whose frame does not move during the
        // collapse; landing below means revealing a moving target.
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a", "b"]), ("latest", ["m1"]), ("genres", ["g1"])]),
            after: rows([("continue", ["a", "b"]), ("genres", ["g1"])]),
            vanished: ShelfFocusID(row: "latest", item: "m1"),
        )
        #expect(next == ShelfFocusID(row: "continue", item: "a"))
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

    @Test func clampsToTheLastSurvivorWhenTheRowShrankPastTheGap() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a", "b", "c"])]),
            after: rows([("continue", ["a"])]),
            vanished: ShelfFocusID(row: "continue", item: "c"),
        )
        #expect(next == ShelfFocusID(row: "continue", item: "a"))
    }

    @Test func aShelfThatAppearedBelowTheGapTakesFocusBeforeOlderRows() {
        let next = HomeFocusReconciler.nextFocus(
            before: rows([("continue", ["a"]), ("genres", ["g1"])]),
            after: rows([("continue", []), ("latest-new", ["n1"]), ("genres", ["g1"])]),
            vanished: ShelfFocusID(row: "continue", item: "a"),
        )
        #expect(next == ShelfFocusID(row: "latest-new", item: "n1"))
    }

    @Test func affinityRowIdsAreDistinctFromGenreAndLatest() {
        #expect(HomeShelfRowID.affinity("genre|Horror") == "affinity-genre|Horror")
        #expect(HomeShelfRowID.affinity("x") != HomeShelfRowID.genre("x"))
        #expect(HomeShelfRowID.affinity("x") != HomeShelfRowID.latest("x"))
    }

    /// A recompute can remove the focused row underneath the viewer. Rows are
    /// matched by id, and focus anchors on the nearest surviving row above.
    @Test func aVanishedAffinityRowLandsFocusInTheRowAbove() {
        let before: [HomeFocusReconciler.Row] = [
            .init(id: HomeShelfRowID.latest("lib"), itemIDs: ["a", "b"]),
            .init(id: HomeShelfRowID.affinity("genre|Horror"), itemIDs: ["h1", "h2"]),
            .init(id: HomeShelfRowID.genre("lib"), itemIDs: ["Horror"]),
        ]
        let after: [HomeFocusReconciler.Row] = [
            .init(id: HomeShelfRowID.latest("lib"), itemIDs: ["a", "b"]),
            .init(id: HomeShelfRowID.genre("lib"), itemIDs: ["Horror"]),
        ]
        let landed = HomeFocusReconciler.nextFocus(
            before: before,
            after: after,
            vanished: ShelfFocusID(row: HomeShelfRowID.affinity("genre|Horror"), item: "h2"),
        )
        #expect(landed?.row == HomeShelfRowID.latest("lib"))
    }

    @Test func aSurvivingAffinityRowKeepsFocusInItself() {
        let before: [HomeFocusReconciler.Row] = [
            .init(id: HomeShelfRowID.affinity("genre|Horror"), itemIDs: ["h1", "h2", "h3"]),
        ]
        let after: [HomeFocusReconciler.Row] = [
            .init(id: HomeShelfRowID.affinity("genre|Horror"), itemIDs: ["h1", "h3"]),
        ]
        let landed = HomeFocusReconciler.nextFocus(
            before: before,
            after: after,
            vanished: ShelfFocusID(row: HomeShelfRowID.affinity("genre|Horror"), item: "h2"),
        )
        #expect(landed?.row == HomeShelfRowID.affinity("genre|Horror"))
    }
}

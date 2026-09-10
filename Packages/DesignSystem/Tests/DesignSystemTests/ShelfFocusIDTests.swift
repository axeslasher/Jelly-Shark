@testable import DesignSystem
import Testing

@Suite("ShelfFocusID")
struct ShelfFocusIDTests {
    @Test func theSameItemInTwoRowsIsTwoDistinctFocusTargets() {
        // A movie can sit in Continue Watching and Recently Added at once.
        // Keyed on the item alone, both cards would claim one focus value
        // and restoration would be ambiguous.
        #expect(
            ShelfFocusID(row: "continue", item: "m-1")
                != ShelfFocusID(row: "latest-movies", item: "m-1"),
        )
    }

    @Test func theSameRowAndItemIsOneTarget() {
        #expect(
            ShelfFocusID(row: "continue", item: "m-1")
                == ShelfFocusID(row: "continue", item: "m-1"),
        )
    }
}

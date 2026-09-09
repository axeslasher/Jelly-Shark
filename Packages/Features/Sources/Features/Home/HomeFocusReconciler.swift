import DesignSystem

/// Decides where tvOS focus lands when the focused shelf card disappears
/// under the viewer — a refresh removing a finished item, or a whole row
/// emptying (#236 § 11.3).
///
/// A pure function on purpose: focus behaviour itself is invisible to
/// every suite in this repo, but *the rule* is not, and shipping the rule
/// untested is how this regression class ships silently.
enum HomeFocusReconciler {
    /// One shelf, in the order it appears down the page. Genre rows are
    /// included — they are focusable rows like any other.
    struct Row: Equatable {
        let id: String
        let itemIDs: [String]
    }

    /// - Parameters:
    ///   - before: the rows as they were when the card had focus
    ///   - after: the rows as they are now
    ///   - vanished: the card that lost its view
    /// - Returns: the card to focus, or nil meaning the hero.
    static func nextFocus(
        before: [Row],
        after: [Row],
        vanished: ShelfFocusID,
    ) -> ShelfFocusID? {
        guard let position = before.firstIndex(where: { $0.id == vanished.row }),
              let index = before[position].itemIDs.firstIndex(of: vanished.item)
        else { return nil }

        // Rows are matched by id, never by position: a removed row lets
        // the one below slide into its index, and treating that as the
        // same row would pick a same-index card from a different shelf.
        if let survivor = after.first(where: { $0.id == vanished.row }), !survivor.itemIDs.isEmpty {
            // Cards to the right shift left into the gap, so the left
            // neighbour is the one that stayed put under the viewer's eye.
            let target = min(max(index - 1, 0), survivor.itemIDs.count - 1)
            return ShelfFocusID(row: survivor.id, item: survivor.itemIDs[target])
        }

        /// The row is gone or empty. Walk the *old* ordering outward, and
        /// take the first row that still exists with something in it.
        func firstLiving(_ candidates: some Sequence<Row>) -> ShelfFocusID? {
            for candidate in candidates {
                guard let now = after.first(where: { $0.id == candidate.id }),
                      let first = now.itemIDs.first
                else { continue }
                return ShelfFocusID(row: now.id, item: first)
            }
            return nil
        }

        return firstLiving(before[(position + 1)...])
            ?? firstLiving(before[..<position].reversed())
    }
}

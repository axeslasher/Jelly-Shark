import DesignSystem

/// The row ids Home's shelves bind, in one place.
///
/// `HomeView.shelfRows` and the views carrying the focus binding must name
/// each row identically, and a mismatch is silent — the reconciler picks a
/// card no view has bound and focus simply goes nowhere (#236 § 11).
enum HomeShelfRowID {
    /// Both the merged lane and the split Continue Watching shelf: they are
    /// the same row to the viewer, and only one is ever on screen.
    static let continueWatching = "continue"
    static let nextUp = "nextUp"

    static func latest(_ libraryID: String) -> String {
        "latest-\(libraryID)"
    }

    static func genre(_ libraryID: String) -> String {
        "genre-\(libraryID)"
    }

    /// One affinity shelf (#86), keyed by the shelf kind's identity rather
    /// than a library id — affinity rows are not per-library.
    static func affinity(_ identity: String) -> String {
        "affinity-\(identity)"
    }
}

/// Decides where tvOS focus lands when the focused shelf card disappears
/// under the viewer — a refresh removing a finished item, or a whole row
/// emptying (#236 § 11.3, with the row-above-first order decided on
/// device).
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

        // The row is gone or empty. Anchor focus in the old layout's
        // ordering (a row that disappeared shouldn't move the viewer), but
        // walk the new layout (a shelf that just appeared is a real row
        // the viewer is looking at, not a phantom to skip).
        let anchorIndex: Int = {
            // Find the nearest row above the vanished position that still exists.
            for i in (0 ..< position).reversed() {
                if after.contains(where: { $0.id == before[i].id }) {
                    return after.firstIndex(where: { $0.id == before[i].id }) ?? -1
                }
            }
            return -1
        }()

        // Above first. Rows above a collapsing row never move, so the focus
        // engine's reveal scroll lands where the card actually is. Rows
        // below are still sliding up into the gap when the reveal runs; on
        // device it scrolled to the card's pre-collapse frame — past the end
        // of the shortened page — and the viewer sat over blank space until
        // the next press clamped it and threw focus to the hero (#236 device
        // round, revising spec § 11.3's next-row-down order).
        if anchorIndex >= 0 {
            for i in (0 ... anchorIndex).reversed() {
                if let first = after[i].itemIDs.first {
                    return ShelfFocusID(row: after[i].id, item: first)
                }
            }
        }

        // Nothing above: the first populated row below, in the new layout.
        for i in (anchorIndex + 1) ..< after.count {
            if let first = after[i].itemIDs.first {
                return ShelfFocusID(row: after[i].id, item: first)
            }
        }

        return nil
    }
}

/// Sends tvOS focus back to where it was when it returns from the sidebar
/// (#340).
///
/// Leaving the sidebar does not restore focus: on the simulator it lands on
/// the topmost visible focusable of the page (the filter bar, or whichever
/// Home row is at the top of the screen), not on what had focus. So a page
/// records what had focus when focus left it, and redirects the first
/// landing after it comes back.
///
/// A pure value on purpose, like the reconciler above: the rule is testable
/// even though focus itself is not.
struct SidebarFocusReturn<Target: Hashable> {
    private var saved: Target?
    private var isAway = false

    /// Focus left the page.
    ///
    /// - Parameter last: what had focus on the page, or nil when nothing
    ///   there needs restoring (the engine's own landing is fine).
    mutating func leave(from last: Target?) {
        saved = last
        isAway = true
    }

    /// Focus came back to the page and landed on `landed`.
    ///
    /// - Returns: where focus must go instead, or nil to leave it where it
    ///   landed. Answers once per departure.
    mutating func reenter(landedOn landed: Target?) -> Target? {
        guard isAway else { return nil }
        isAway = false
        defer { saved = nil }
        guard let saved, saved != landed else { return nil }
        return saved
    }

    /// Where focus is on a page: the tracked item, or `isOnPage` alone for
    /// a focusable that needs no restoring. Neither means focus is elsewhere,
    /// such as the sidebar or a pushed screen.
    struct Snapshot: Equatable {
        let target: Target?
        let isOnPage: Bool

        init(_ target: Target?, isOnPage: Bool = false) {
            self.target = target
            self.isOnPage = isOnPage || target != nil
        }
    }

    /// One focus move on a page that tracks itself with a `Snapshot`.
    ///
    /// - Returns: where focus must go instead of `new`, or nil.
    mutating func move(from old: Snapshot, to new: Snapshot) -> Target? {
        if !new.isOnPage {
            leave(from: old.target)
        } else if !old.isOnPage {
            return reenter(landedOn: new.target)
        }
        return nil
    }
}

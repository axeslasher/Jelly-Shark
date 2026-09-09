import DesignSystem
import Foundation
import Observation

/// Home's scroll and focus state, owned above the tab.
///
/// tvOS tears a tab's view down on switch, so anything `@State` in
/// `HomeView` — `scrollPosition`, `focusedRegion` — dies with it, and the
/// tab returns scrolled to the top with focus on the hero. Hoisting the
/// view models restores the *data*; this restores where the viewer was
/// standing in it (#236 § 3).
@MainActor
@Observable
public final class HomeUIState {
    /// Last known scroll offset, in the same inset-adjusted space
    /// `HomeView` already tracks.
    public var scrollOffset: CGFloat = 0

    /// The shelf card that owned focus, or nil.
    public var focusedItem: ShelfFocusID?

    /// Whether focus was on the hero rather than a shelf. Stored
    /// separately from `focusedItem` being nil: "nothing was focused yet"
    /// and "the hero was focused" restore differently, and conflating them
    /// sent a returning viewer back to a stale card.
    public var focusIsOnHero = true

    /// Whether this appearance has already restored, so a later body pass
    /// does not yank the viewer back to a stale offset.
    public var hasRestoredThisAppearance = false

    public init() {}
}

import DesignSystem
import Observation

/// Which card had focus on each library tab, kept above the tabs so a tab
/// return can put focus back, as Home's does (#340).
///
/// The page's own state can't hold it: tvOS tears a tab's view down when
/// another tab is selected. Measured on the simulator, a library tab gets a
/// new view model each time it is selected again.
///
/// Nothing renders from this, so nothing observes it: a write on every
/// focus move must not re-evaluate `RootView`.
@Observable @MainActor
final class LibraryFocusMemory {
    @ObservationIgnored private var cards: [String: ShelfFocusID] = [:]

    /// The card that last had focus in a library, or nil when the filter
    /// bar did, or nothing yet.
    subscript(library: String) -> ShelfFocusID? {
        get { cards[library] }
        set { cards[library] = newValue }
    }
}

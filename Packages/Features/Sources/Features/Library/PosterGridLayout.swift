import DesignSystem
import SwiftUI

/// Poster-column math shared by the library grid and Home's Recently Added
/// shelves, so posters render the same size everywhere they appear.
///
/// Poster cards need an explicit width, so neither surface can rely on
/// adaptive columns (cards would float centered inside stretched columns,
/// insetting the edges). Instead callers measure their available width and
/// size cards to exactly fill the columns, flush both edges.
enum PosterGridLayout {
    /// Narrowest a poster may render; columns are added until one more
    /// would squeeze cards below this.
    static let minimumCardWidth: CGFloat = 220

    /// How many columns fit `availableWidth`, and the exact card width
    /// that fills them.
    static func columns(for availableWidth: CGFloat) -> (count: Int, width: CGFloat) {
        let gap = SpacingTokens.cardGap
        guard availableWidth > minimumCardWidth else { return (1, minimumCardWidth) }
        let count = max(1, Int((availableWidth + gap) / (minimumCardWidth + gap)))
        let width = (availableWidth - gap * CGFloat(count - 1)) / CGFloat(count)
        return (count, width)
    }
}

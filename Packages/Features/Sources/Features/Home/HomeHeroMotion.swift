import DesignSystem
import SwiftUI

/// Every layout and motion knob for the Home hero in one place, so design
/// iteration on the marquee's feel touches a single file. Timing derives from
/// the active theme (`theme.animation`) — these are the shape parameters.
enum HomeHeroMotion {
    /// Fraction of the container the hero occupies; the remainder is the
    /// Continue Watching peek above the fold.
    static let heroHeightFraction: CGFloat = 0.85

    /// Gap between the hero's bottom edge and the Continue Watching row —
    /// deliberately tighter than the `sectionSpacing` used between shelves,
    /// so the peeking row hugs the hero.
    static let heroToShelvesGap: CGFloat = SpacingTokens.md

    /// Full-bleed backdrop canvas height (matches the previous Home hero).
    static let backdropHeight: CGFloat = 1080

    /// Where the backdrop's bottom fade begins/ends, as fractions of its
    /// height — the image is gone before the shelves start.
    static let backdropFadeStart: CGFloat = 0.6
    static let backdropFadeEnd: CGFloat = 0.9

    /// Leading scrim behind the left-stacked lockup: opacity at the screen
    /// edge and where it fades to clear (fraction of the width).
    static let scrimEdgeOpacity: Double = 0.75
    static let scrimEnd: CGFloat = 0.55

    /// Scroll distance ignored before the hero's exit begins — dead-bands the
    /// tvOS focus engine's small settle so the hero stays put until the
    /// scroll is a deliberate move toward the shelves.
    static let exitThreshold: CGFloat = 60

    /// Points of scrolling over which the hero fully fades and drifts out
    /// (progress 0 → 1). Smaller = snappier exit; larger = more gradual.
    static let exitDistance: CGFloat = 350

    /// Extra upward drift of the lockup at full exit progress, on top of its
    /// natural scroll movement — the hero leaves faster than the page.
    /// Offset only, never opacity: faded-out controls become unfocusable on
    /// tvOS, which strands the scroll (see MediaDetailView).
    static let exitDrift: CGFloat = -240

    /// Exit progress at which the Continue Watching header fades/slides in.
    /// While the hero owns the screen the peeking shelf stays headerless;
    /// the title arrives as the hero leaves.
    static let shelfHeaderReveal: CGFloat = 0.8

    /// Offsets closer than this to a snap target skip the snap — redundant
    /// assertions during fast focus movement are what the scroll-jack was
    /// made of.
    static let snapSlack: CGFloat = 24

    /// Horizontal page slide: the incoming item enters from the trailing
    /// edge while the outgoing one exits leading, with a fade riding along.
    /// (Computed because `AnyTransition` isn't `Sendable`, so a stored static
    /// trips strict concurrency.)
    static var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity),
        )
    }

    /// Fixed logo lockup box (same footprint recipe as the detail hero).
    static let logoWidth: CGFloat = 480
    static let logoHeight: CGFloat = 220

    /// Measure cap for the hero overview so lines stay readable.
    static let overviewMaxWidth: CGFloat = 760

    /// Page indicator dots.
    static let dotHeight: CGFloat = 8
    static let dotWidth: CGFloat = 8
    static let activeDotWidth: CGFloat = 26
    /// How far below the hero's bottom edge the dots hang (into the
    /// hero→shelves gap).
    static let dotsDrop: CGFloat = 12
}

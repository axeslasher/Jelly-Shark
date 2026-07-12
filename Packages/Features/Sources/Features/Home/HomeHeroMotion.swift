import DesignSystem
import SwiftUI

/// Every layout and motion knob for the Home hero in one place, so design
/// iteration on the marquee's feel touches a single file. Timing derives from
/// the active theme (`theme.animation`) — these are the shape parameters.
enum HomeHeroMotion {
    /// Fraction of the container the hero occupies; the remainder is the
    /// Continue Watching peek above the fold.
    static let heroHeightFraction: CGFloat = 0.93

    /// Gap between the hero's bottom edge and the Continue Watching row —
    /// deliberately tighter than the `sectionSpacing` used between shelves,
    /// so the peeking row hugs the hero.
    static let heroToShelvesGap: CGFloat = SpacingTokens.sm

    /// Full-bleed backdrop canvas height (matches the previous Home hero).
    static let backdropHeight: CGFloat = 1080

    /// Where the backdrop's bottom fade begins/ends, as fractions of its
    /// height — the image is gone before the shelves start.
    static let backdropFadeStart: CGFloat = 0.6
    static let backdropFadeEnd: CGFloat = 1.1

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
    static let shelfHeaderReveal: CGFloat = 1

    /// Offsets closer than this to a snap target skip the snap — redundant
    /// assertions during fast focus movement are what the scroll-jack was
    /// made of.
    static let snapSlack: CGFloat = 24

    /// Fixed logo lockup box (same footprint recipe as the detail hero).
    static let logoWidth: CGFloat = 480
    static let logoHeight: CGFloat = 220

    /// Measure cap for the hero overview so lines stay readable.
    static let overviewMaxWidth: CGFloat = 560

    /// Bottom padding inside each marquee page — sized so the circle
    /// buttons' focus-revealed hanging labels fit (pages clip to their
    /// bounds, unlike the shelves' clip-disabled scrolls).
    static let controlsBottomClearance: CGFloat = 48

    // MARK: Page-turn choreography (the Apple TV app pattern)

    //
    // On a page turn the lockup and controls never slide — they fade out,
    // the backdrop slides in behind them, and they fade back in once the
    // turn settles, with focus granted to the direction-appropriate control.
    // The fade isn't decoration: it hides the focus engine's default landing,
    // the Play/Resume relabel, and any layout settle, all of which read as
    // jank when visible.

    /// How fast the lockup + controls drop out as a turn begins.
    static let contentFadeOutDuration: TimeInterval = 0.15

    /// How the content returns once the turn settles — slower than the
    /// fade-out so the reveal reads as deliberate.
    static let contentFadeInDuration: TimeInterval = 0.4

    /// Time from the index change until focus is steered and the content
    /// fades back in. Must outlast the native page slide (and the backdrop
    /// slide) so the steer lands on a settled focus engine — asserting focus
    /// mid-turn is what made retreats bounce back.
    static let pageSettleDelay: TimeInterval = 0.6

    /// The faded-out content parks here, not at 0: fully transparent
    /// controls become unfocusable on tvOS, and the focus engine needs the
    /// buttons alive mid-turn to resolve its landing.
    static let contentFadeFloor: Double = 0.01

    /// How long an anticipated turn (edge press observed by `onMoveCommand`)
    /// may keep the content faded before it's restored — covers the case
    /// where the engine resolved the press to something other than a page
    /// turn, so the marquee never sticks in its faded state.
    static let anticipationTimeout: TimeInterval = 1.0

    /// How long focus must have been parked on Play/Next before a press is
    /// treated as an edge press: `onMoveCommand` arrives after focus has
    /// already moved for the same press, so the move that lands ON the
    /// control is indistinguishable from an edge press except by this dwell.
    static let anticipationDwell: TimeInterval = 0.2

    /// Cold-start beat between the backdrop appearing and the content's
    /// first fade-in (blurhash → artwork → lockup, per the system marquee).
    static let initialRevealDelay: TimeInterval = 0.35

    /// How long the outgoing backdrop stays fully opaque while the incoming
    /// one slides over it — sized to the theme animation so the old image
    /// never fades before it's covered (that read as a dark band at the
    /// uncovered edge).
    static let backdropOutgoingHold: TimeInterval = 0.3

    /// The outgoing backdrop's quick release after the hold.
    static let backdropOutgoingFadeDuration: TimeInterval = 0.2

    /// Page indicator dots.
    static let dotHeight: CGFloat = 8
    static let dotWidth: CGFloat = 8
    static let activeDotWidth: CGFloat = 26
    /// How far below the hero's bottom edge the dots hang (into the
    /// hero→shelves gap).
    static let dotsDrop: CGFloat = 42
}

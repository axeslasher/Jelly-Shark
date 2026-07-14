import DesignSystem
import JellyfinKit
import SwiftUI

/// The Home marquee's foreground: a native paged `TabView` of slides, each a
/// left-stacked lockup (logo, overview, metadata) over its own controls row —
/// Play, Details, Next — with custom page dots overlaying the bottom edge.
///
/// Paging rides the platform's paged tab view (the system marquee primitive),
/// so the remote interactions come free and match the Apple TV app's pattern:
/// focus walks the button row; left/right at the row's edges turn pages;
/// left on the first page exits to the sidebar.
///
/// The visible transition is the Apple TV app's fade choreography, not the
/// page slide: on any turn the lockup and controls fade out, the backdrop
/// (owned by `HomeHeroBackdrop`) slides in behind them, and once the turn
/// settles focus is granted to the direction-appropriate control and the
/// content fades back in. The pages themselves still slide, but their
/// content is invisible while they do — the fade is what hides the focus
/// engine's default landing and the Play/Resume relabel.
struct HomeHeroSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let items: [MediaItem]
    let index: Int
    /// Which way the current page turn went — aims the post-turn focus
    /// landing (advance → Next, retreat → Play, matching the button the
    /// user's thumb is already on).
    let pagingDirection: HomeViewModel.PagingDirection
    /// Bumped by the view model's auto-advance timer; the view answers each
    /// request with the same pre-faded advance the Next button uses, so a
    /// timed turn never pops the incoming content in before its fade.
    let advanceRequests: Int
    /// What Play starts for the current item — nil no-ops the button
    /// (still resolving, or a box set).
    let playTarget: MediaItem?
    let onPlay: (MediaItem) -> Void
    let onNext: () -> Void
    /// A user-driven page change (edge navigation or swipe) — the owner
    /// records it and resets the auto-advance countdown.
    let onSelect: (Int) -> Void

    /// Which button on which page holds focus — the choreography's steer
    /// target after a turn settles.
    private struct HeroFocus: Hashable {
        var page: Int
        var control: Control

        enum Control: Hashable {
            case play
            case details
            case next
        }
    }

    @FocusState private var heroFocus: HeroFocus?

    /// False while a page turn (or the cold start) owns the screen; drives
    /// the lockup + controls fade. Never fades to zero — see
    /// `HomeHeroMotion.contentFadeFloor`.
    @State private var isContentVisible = false
    @State private var transitionTask: Task<Void, Never>?

    /// The page whose content is allowed to show. Unlike `index` — which an
    /// interactive swipe flips MID-slide, lighting up the incoming page's
    /// content while it's still moving — this only advances when a turn's
    /// choreography settles, right before the fade-in. A page arriving by
    /// any route stays empty until its backdrop has landed.
    @State private var settledIndex = 0

    /// The index whose turn choreography already ran — a native turn reaches
    /// the choreography twice (selection binding, then `onChange`), and only
    /// the first call may configure it.
    @State private var choreographedIndex: Int?

    /// When focus last moved between the marquee's controls. `onMoveCommand`
    /// arrives after the engine has already moved focus for the same press,
    /// so the press that *lands* focus on Next reads exactly like an edge
    /// press *on* Next — the tell is that on a real edge press focus has
    /// been parked on the control for a beat, not freshly arrived.
    @State private var focusChangedAt: Date = .distantPast

    /// Where the focus engine should land when it moves into a page on its
    /// own: the button the user's thumb is already on (advance → Next,
    /// retreat → Play).
    private var landingControl: HeroFocus.Control {
        pagingDirection == .backward ? .play : .next
    }

    private var fadeOutAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: HomeHeroMotion.contentFadeOutDuration)
    }

    private var fadeInAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: HomeHeroMotion.contentFadeInDuration)
    }

    /// Selection bridge: reads the owner's index, reports user paging back.
    /// Native turns run the choreography from here WITHOUT a focus steer —
    /// the engine handles its own landing (guided by each page's
    /// `defaultFocus`), and asserting `heroFocus` on top of an in-flight
    /// native turn is what rubber-banded retreats back to the outgoing page.
    private var selection: Binding<Int> {
        Binding(
            get: { index },
            set: { newIndex in
                onSelect(newIndex)
                runTurnChoreography(to: newIndex, steer: false)
            },
        )
    }

    var body: some View {
        TabView(selection: selection) {
            // Key on element identity, not position: when `items` is replaced
            // (single-item fallback, reconnect reload) index-based identity
            // keeps page N's view — and its per-page @FocusState, fade
            // choreography, and image state — attached while the content swaps
            // underneath. The Int `.tag` stays: `selection` is a `Binding<Int>`.
            ForEach(Array(items.enumerated()), id: \.element.id) { pageIndex, item in
                page(for: item, at: pageIndex)
                    .tag(pageIndex)
            }
        }
        // No implicit animation here: the paged style animates user paging
        // itself, and programmatic turns don't need a visible slide — their
        // content is faded out while the page changes. (tvOS has no carousel
        // TabView style — `.carousel` is watchOS-only — so the marquee rides
        // the paged style everywhere.)
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Bottom-anchored fractional hero: the lockup grows upward into the
        // backdrop and the Continue Watching row peeks above the fold (see
        // MediaDetailHeroSection for the anchoring rationale).
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
            height * HomeHeroMotion.heroHeightFraction
        }
        // Page dots hang just below the hero's bottom edge, centered in the
        // hero→shelves gap — an overlay so they never participate in the
        // pages' layout (and never fade with it, matching the system marquee).
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                pageDots
                    .offset(y: HomeHeroMotion.dotsDrop)
            }
        }
        // Programmatic turns (Next button, timer) never touch the selection
        // binding, so they enter the choreography here — with a steer, since
        // the engine won't move focus off the outgoing page on its own.
        // (For native turns this fires after the binding already ran the
        // choreography; `choreographedIndex` makes it a no-op.)
        .onChange(of: index) { _, newIndex in
            runTurnChoreography(to: newIndex, steer: true)
        }
        .onChange(of: heroFocus) { _, _ in
            focusChangedAt = Date.now
        }
        .onChange(of: advanceRequests) { _, _ in
            performProgrammaticAdvance()
        }
        // Cold start (steps the system marquee takes): backdrop first, then
        // the content's first fade-in once items exist.
        .onChange(of: items.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, !isContentVisible else { return }
            revealContent(after: HomeHeroMotion.initialRevealDelay)
        }
    }

    // MARK: - Turn choreography

    /// Fade out → let the page turn and backdrop settle → (programmatic
    /// turns only) steer focus → fade back in. A turn arriving
    /// mid-choreography restarts it, so the content stays down until the
    /// final page settles.
    private func runTurnChoreography(to newIndex: Int, steer: Bool) {
        guard choreographedIndex != newIndex else { return }
        choreographedIndex = newIndex
        transitionTask?.cancel()
        // Even for programmatic turns, only steer when focus is already
        // inside the marquee (the Next button). A timer advance while focus
        // sits in the sidebar must not yank focus into the hero.
        let shouldSteer = steer && heroFocus != nil
        let landing = landingControl

        transitionTask = Task { @MainActor in
            withAnimation(fadeOutAnimation) {
                isContentVisible = false
            }
            try? await Task.sleep(for: .seconds(HomeHeroMotion.pageSettleDelay))
            guard !Task.isCancelled else { return }
            if shouldSteer {
                heroFocus = HeroFocus(page: newIndex, control: landing)
            }
            // Unlock the new page's content before the animated fade — the
            // content is still down (`isContentVisible` false), so this
            // can't flash; the fade-in is its single appearance.
            settledIndex = newIndex
            withAnimation(fadeInAnimation) {
                isContentVisible = true
            }
        }
    }

    /// A programmatic turn (Next button, timer) fades the current content
    /// out FIRST, then changes the index — flipping the index immediately
    /// would snap the viewport to the next page's content at full opacity
    /// before any fade could run. Already-faded content advances at once,
    /// so rapid Next presses don't swallow turns.
    private func performProgrammaticAdvance() {
        guard items.count > 1 else { return }
        if !isContentVisible {
            onNext()
            return
        }
        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            withAnimation(fadeOutAnimation) {
                isContentVisible = false
            }
            try? await Task.sleep(for: .seconds(HomeHeroMotion.contentFadeOutDuration))
            guard !Task.isCancelled else { return }
            onNext()
        }
    }

    #if os(tvOS)
        /// A native turn only reports through the selection binding once its
        /// slide COMPLETES — waiting for that would show the content sliding
        /// at full opacity first (the opposite of the fade-first pattern).
        /// `onMoveCommand` observes the press that starts the turn without
        /// consuming it, so the fade can begin as the slide does. If the
        /// anticipated turn never lands, the timeout brings the content back.
        private func anticipatePageTurn(_ direction: MoveCommandDirection, from pageIndex: Int) {
            // Skip when this very press is the one that moved focus onto the
            // control (fresh arrival) — only a press on an already-parked
            // control is an edge press about to turn the page. Rapid input
            // that fails the dwell just degrades to the un-anticipated fade.
            guard Date.now.timeIntervalSince(focusChangedAt) >= HomeHeroMotion.anticipationDwell else { return }
            let advancing = direction == .right
                && heroFocus?.control == .next
                && pageIndex < items.count - 1
            let retreating = direction == .left
                && heroFocus?.control == .play
                && pageIndex > 0
            guard advancing || retreating else { return }

            transitionTask?.cancel()
            transitionTask = Task { @MainActor in
                withAnimation(fadeOutAnimation) {
                    isContentVisible = false
                }
                try? await Task.sleep(for: .seconds(HomeHeroMotion.anticipationTimeout))
                guard !Task.isCancelled else { return }
                withAnimation(fadeInAnimation) {
                    isContentVisible = true
                }
            }
        }
    #endif

    private func revealContent(after delay: TimeInterval) {
        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            settledIndex = index
            withAnimation(fadeInAnimation) {
                isContentVisible = true
            }
        }
    }

    // MARK: - Pages

    private func page(for item: MediaItem, at pageIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.lg) {
            lockup(for: item)
            controls(for: item, at: pageIndex)
        }
        // The choreography's fade — floor, not zero, so the controls stay
        // focusable while invisible (the engine resolves its mid-turn landing
        // on them, and fully transparent views drop out of focus on tvOS).
        // Only the SETTLED page shows content: an incoming page slides in
        // empty during the native turn (even after a mid-slide selection
        // flip), so its content never appears ahead of its backdrop — it
        // arrives with the post-settle fade-in.
        .opacity(isContentVisible && pageIndex == settledIndex ? 1 : HomeHeroMotion.contentFadeFloor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        // Clearance instead of the usual bottom margin: pages clip to their
        // bounds (unlike the shelves' clip-disabled scrolls), so the circle
        // buttons' focus-revealed hanging labels need room to render.
        .padding(.bottom, HomeHeroMotion.controlsBottomClearance)
        // A hint, not an assert: when a native turn moves focus into this
        // page, the engine lands it on the direction-appropriate control —
        // the same position the user's thumb was on, so focus reads as
        // parked while the marquee turns beneath it.
        .defaultFocus($heroFocus, HeroFocus(page: pageIndex, control: landingControl))
        #if os(tvOS)
            .onMoveCommand { direction in
                anticipatePageTurn(direction, from: pageIndex)
            }
        #endif
    }

    private func lockup(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: SpacingTokens.md) {
            titleTreatment(for: item)

            // Fact row and overview read as one block — tighter spacing
            // inside the pair than the lockup's stride between elements.
            VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                // A slimmed-down cut of the detail hero's fact row sits
                // between the logo and the overview: ratings and certificate
                // (plus a new-episode count for a series). Renders nothing
                // when every field is nil.
                MediaMetadataRow(
                    yearText: nil,
                    runtime: nil,
                    seasons: newEpisodesText(for: item),
                    seasonsIcon: "tv",
                    communityRating: item.communityRating,
                    criticRating: item.criticRating,
                    certificate: item.officialRating,
                    resolution: nil,
                    videoRange: nil,
                    audioFormat: nil,
                )
                if let overview = item.overview {
                    Text(overview)
                        .jsStyle(.overview)
                        .foregroundStyle(theme.primary)
                        .lineLimit(3)
                        .frame(maxWidth: HomeHeroMotion.overviewMaxWidth, alignment: .leading)
                }
            }
            if let metadataLine = metadataLine(for: item) {
                Text(metadataLine)
                    .jsStyle(.caption, .emphasized)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Logo lockup with text fallback — the same `TrimmedLogoImage` recipe as
    /// the detail hero (fixed bottom-leading box so content below never shifts).
    @ViewBuilder
    private func titleTreatment(for item: MediaItem) -> some View {
        if let client = session.client, let url = client.logoURL(for: item) {
            TrimmedLogoImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: HomeHeroMotion.logoWidth,
                        height: HomeHeroMotion.logoHeight,
                        alignment: .bottomLeading,
                    )
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
            } fallback: {
                titleText(for: item)
            }
        } else {
            titleText(for: item)
        }
    }

    private func titleText(for item: MediaItem) -> some View {
        Text(item.name)
            .jsStyle(.display)
            .foregroundStyle(theme.primary)
    }

    /// "20 New Episodes" for a series in the marquee. Hero series entries
    /// come from `/Latest`, which groups new episodes under a series-shaped
    /// item and repurposes `childCount` as the group's size — NOT the season
    /// count it means on a directly-fetched series. Local to the hero on
    /// purpose: nowhere else is that reading of `childCount` valid.
    private func newEpisodesText(for item: MediaItem) -> String? {
        guard item.type == .series, let count = item.childCount, count > 0 else { return nil }
        return count == 1 ? "1 New Episode" : "\(count) New Episodes"
    }

    /// One subdued line: year · up to three genres.
    private func metadataLine(for item: MediaItem) -> String? {
        var parts: [String] = []
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if let genres = item.genres, !genres.isEmpty {
            parts.append(contentsOf: genres.prefix(3))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: - Controls (per page)

    private func controls(for item: MediaItem, at pageIndex: Int) -> some View {
        HStack(alignment: .center, spacing: SpacingTokens.sm) {
            playButton(for: item, at: pageIndex)
                .focused($heroFocus, equals: HeroFocus(page: pageIndex, control: .play))

            CircleNavigationLink(
                systemImage: "info.circle.text.page.fill",
                title: "Details",
                value: item,
            )
            .focused($heroFocus, equals: HeroFocus(page: pageIndex, control: .details))

            CircleActionButton(
                systemImage: "chevron.forward",
                title: "Next",
                tint: theme.primary,
                isEnabled: items.count > 1,
            ) {
                performProgrammaticAdvance()
            }
            .focused($heroFocus, equals: HeroFocus(page: pageIndex, control: .next))
        }
    }

    /// The label reads the item's own state (not the async-resolved play
    /// target), so a settled page never re-lays-out — the target flip at
    /// page turns was re-bouncing the whole lockup. Always focusable — Play
    /// is the marquee's left edge (paging and the sidebar exit both hang off
    /// it), so a missing target (still resolving, box set) no-ops the action
    /// instead of disabling the button.
    private func playButton(for item: MediaItem, at pageIndex: Int) -> some View {
        Button {
            guard pageIndex == index, let playTarget else { return }
            onPlay(playTarget)
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: "play.fill")
                Text(item.hasProgress ? "Resume" : "Play")
            }
            .jsStyle(.headline)
        }
        .glassButtonStyle(tint: theme.focusFill)
    }

    /// Display-only page indicators; paging is driven by edge navigation,
    /// the Next button, and the auto-advance timer.
    private var pageDots: some View {
        HStack(spacing: SpacingTokens.xs) {
            ForEach(Array(items.enumerated()), id: \.element.id) { dotIndex, _ in
                Capsule()
                    .fill(dotIndex == index ? theme.accent : theme.tertiary.opacity(0.4))
                    .frame(
                        width: dotIndex == index ? HomeHeroMotion.activeDotWidth : HomeHeroMotion.dotWidth,
                        height: HomeHeroMotion.dotHeight,
                    )
            }
        }
        .animation(reduceMotion ? nil : theme.animation, value: index)
        .accessibilityHidden(true)
    }
}

/// `CircleActionButton`'s value-based-navigation twin: the same circular glass
/// treatment and focus-revealed hanging label, but pushing a destination
/// instead of running an action.
private struct CircleNavigationLink<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    let systemImage: String
    let title: String
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            Image(systemName: systemImage)
                .jsStyle(.headline)
                .foregroundStyle(isFocused ? theme.onFocusFill : theme.primary)
                // Fixed glyph box so every circle renders the same size
                // (matches CircleActionButton).
                .frame(width: 44, height: 44)
        }
        .glassButtonStyle(tint: theme.focusFill, circular: true)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .focused($isFocused)
        .overlay(alignment: .bottom) {
            Text(title)
                .jsStyle(.caption)
                .foregroundStyle(theme.secondary)
                .fixedSize()
                .opacity(isFocused ? 1 : 0)
                .alignmentGuide(.bottom) { $0[.top] - SpacingTokens.sm }
        }
        .animation(theme.animation, value: isFocused)
    }
}

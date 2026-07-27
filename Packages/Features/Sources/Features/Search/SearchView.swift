import DesignSystem
import JellyfinKit
import SwiftUI

/// Search screen for finding media across the user's libraries
struct SearchView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @State private var viewModel = SearchViewModel()

    /// No NavigationStack here: RootView owns each tab's stack (with a path
    /// binding) so it can pop to root before a tab switch — see RootView's
    /// `tabSelection` for the tvOS bug this works around.
    var body: some View {
        content
            .searchable(text: $viewModel.query, prompt: "Search movies, shows…")
            .searchSuggestions {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Text(suggestion)
                        .searchCompletion(suggestion)
                }
            }
            .onChange(of: viewModel.query) { _, newValue in
                viewModel.updateQuery(newValue)
            }
            .task(id: session.isConnected) {
                viewModel.attach(client: session.client)
            }
            // Outside `.searchable`: applied to `content` it stopped at the
            // results, leaving the headroom RootView opens above the field as
            // bare system chrome rather than themed background (#148).
            .background(theme.background)
    }

    /// One `ScrollView` for every state, deliberately hoisted above the switch.
    ///
    /// Each state used to bring its own — skeletons and results were separate
    /// `ScrollView`s in separate switch branches — so any transition destroyed
    /// one `HostingScrollView` and built another. That crashed the app when a
    /// search was started from the system search UI's suggestion list: the
    /// press moves focus, the focus engine asks the content area's scroll view
    /// for its scroll-boundary metrics, and `.results → .searching` had already
    /// replaced the scroll view underneath it. AttributeGraph then aborts with
    /// "accessing attribute in a different namespace" — a stale graph node,
    /// reached from a live focus update. Nothing visible is torn down, which is
    /// what made it look like a freeze rather than a view-identity problem.
    ///
    /// Keeping the scroll view mounted keeps that graph node alive across the
    /// transition. Its *contents* still swap freely; only the container has to
    /// persist, because the container is what UIKit holds a reference to.
    private var content: some View {
        ScrollView {
            stateContent
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .idle:
            fullHeight { prompt }
        case .searching:
            skeletonShelves
        case .empty:
            fullHeight {
                message(
                    icon: "magnifyingglass",
                    text: "No results for \"\(viewModel.query)\"",
                )
            }
        case let .failed(errorMessage):
            fullHeight {
                message(icon: "exclamationmark.triangle.fill", text: errorMessage)
            }
        case .results:
            resultsShelves
        }
    }

    /// Sizes a state that wants to fill the screen and centre itself.
    ///
    /// `maxHeight: .infinity` no longer does that now these states live inside
    /// a scroll view — scroll content is sized to fit, so an infinite maximum
    /// resolves to the content's own height and the prompt would sit jammed
    /// under the search field. `containerRelativeFrame` measures the scroll
    /// view's visible height instead, which is what "fill the screen" meant
    /// before the hoist.
    private func fullHeight(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
    }

    /// The empty state. Seeded titles when the server offered any; otherwise —
    /// on an error, an empty library, or before the fetch lands — the plain
    /// prompt this screen has always shown.
    @ViewBuilder
    private var prompt: some View {
        if viewModel.seedTerms.isEmpty {
            plainPrompt
        } else {
            seedTermPrompt
        }
    }

    private var plainPrompt: some View {
        promptHeader
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, SpacingTokens.sm)
    }

    /// The glyph and copy, shown whether or not the server had terms to offer.
    /// It says what the screen is for; the terms below say where to start.
    private var promptHeader: some View {
        VStack(spacing: SpacingTokens.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(theme.secondary)

            Text("Search Your Library")
                .jsStyle(.headline)
                .foregroundStyle(theme.primary)

            Text("Find movies, shows, and more")
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
        }
    }

    private var seedTermPrompt: some View {
        VStack(spacing: SpacingTokens.md) {
            promptHeader

            // A plain stack, not a scroll view: `seedTermLimit` is set so the
            // column fits without scrolling, which keeps this out of the
            // vertical-overflow trap that bit the Home shelves (#28) and means
            // every pill is built and reachable by the focus engine.
            VStack(spacing: SpacingTokens.sm) {
                ForEach(viewModel.seedTerms) { item in
                    Button {
                        viewModel.selectSeedTerm(item.name)
                    } label: {
                        // No explicit `foregroundStyle`: an explicit one wins
                        // over the style's, which is what left the label at
                        // `primary` on a focused platter. Left alone, the style
                        // resolves `primary` at rest and `onFocusFill` on focus,
                        // per theme.
                        Text(item.name)
                            .jsStyle(.title)
                    }
                    // The plain glass style, unlike the season pills': these
                    // pills have no active-item gate keyed to what pressing
                    // one changes, so the style presents its own focus and
                    // sees every press through.
                    .glassButtonStyle(tint: theme.focusFill)
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(theme.secondary)

            Text(text)
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ghost mirror of `resultsShelves` while a search is in flight, in their
    /// order: two poster rows (Movies, TV Series) and a stills row (Episodes),
    /// so results land where the ghosts were.
    ///
    /// The ghosts are pure shapes and non-focusable, which is required rather
    /// than incidental: focus stays in the search field and the viewer can
    /// keep typing while the round of queries is out.
    private var skeletonShelves: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            SkeletonShelf(cardWidth: 200, shape: .artwork(aspectRatio: 2.0 / 3.0))
            SkeletonShelf(cardWidth: 200, shape: .artwork(aspectRatio: 2.0 / 3.0))
            SkeletonShelf(
                cardWidth: 320,
                shape: .artwork(aspectRatio: 16.0 / 9.0),
                cardCount: 4,
            )
        }
        .padding(.vertical, SpacingTokens.lg)
        .skeletonPulse()
    }

    /// Results grouped by item type, in a fixed Movies → TV Series → Episodes
    /// order — the same order as the person page's filmography, so the two
    /// pages don't disagree. A type with no matches renders nothing, so the
    /// first shelf on screen is whichever type matched first.
    ///
    /// A plain `VStack`, not a `LazyVStack`: on tvOS the focus engine can't
    /// move focus into a section a lazy stack hasn't built yet. And no
    /// scroll-target behaviour or focus-region snap — that machinery exists on
    /// Home and Media Detail to park a hero, and this page (like the person
    /// page it follows) has none.
    private var resultsShelves: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            SearchShelfSection(
                title: "Movies", icon: "film.fill",
                items: viewModel.movies, style: .poster,
            )
            SearchShelfSection(
                title: "TV Series", icon: "tv.fill",
                items: viewModel.series, style: .poster,
            )
            SearchShelfSection(
                title: "Episodes", icon: "play.tv",
                items: viewModel.episodes, style: .landscape,
            )
        }
        .padding(.vertical, SpacingTokens.lg)
        // One focus region for the whole stack, not one per shelf: moving
        // between rows is a plain vertical move, and moving up out of the
        // first shelf leaves for the search field above it.
        #if os(tvOS)
            .focusSection()
        #endif
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

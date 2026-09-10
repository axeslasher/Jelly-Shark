import DesignSystem
import JellyfinKit
import SwiftUI

/// Renders Home's affinity shelves (#86): up to three poster rows built by
/// `AffinityShelvesViewModel`. A pure renderer, like `GenreShelvesView` —
/// the model is owned by `RootView` so the rows survive tvOS tearing the
/// tab down on switch.
///
/// Two empty cases, not one. Empty and succeeded renders nothing at all —
/// no empty state, no spinner — because a suppressed affinity section is
/// Home exactly as it is today. Empty and failed renders the failed notice
/// with Retry; otherwise a cold launch with no cache and a failed first pass
/// silently shows nothing and offers no way back.
struct AffinityShelvesView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let shelves: [CachedAffinityShelf]
    let status: AffinityShelvesViewModel.Status
    /// Long-press menu handlers per item, built by the owner the same way
    /// the Recently Added rows get theirs.
    let menu: (MediaItem) -> ShelfMenuHandlers
    /// Retry action for the failed notice (`AffinityShelvesViewModel.retry`).
    let onRetry: () -> Void
    /// Affinity rows are focusable like any other shelf, so they carry the
    /// page's focus binding too — `HomeView.shelfRows` lists them, and the
    /// ids bound here must match those exactly or focus goes nowhere when a
    /// card vanishes (§ 11.1). Nil in previews.
    var focusBinding: FocusState<ShelfFocusID?>.Binding?

    /// Measured section width, feeding the shared poster-column math so
    /// affinity posters match the Recently Added rows above them exactly.
    @State private var sectionWidth: CGFloat = 0

    private var posterWidth: CGFloat {
        guard sectionWidth > 0 else { return PosterGridLayout.minimumCardWidth }
        return PosterGridLayout.columns(for: sectionWidth - SpacingTokens.screenPadding * 2).width
    }

    private var itemTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92))
                .animation(reduceMotion ? nil : HomeHeroMotion.shelfItemInsert),
            removal: .opacity
                .combined(with: .scale(scale: 0.88))
                .animation(reduceMotion ? nil : HomeHeroMotion.shelfItemExit),
        )
    }

    private var rowTransition: AnyTransition {
        .opacity
            .animation(reduceMotion ? nil : HomeHeroMotion.shelfRowCollapse)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
            ForEach(shelves, id: \.descriptor.id) { shelf in
                ContentShelf(shelf.descriptor.title, icon: Self.icon(for: shelf.descriptor.kind)) {
                    ForEach(shelf.items) { item in
                        item.posterShelfItem(
                            client: session.client,
                            width: posterWidth,
                            menu: menu(item),
                            focusBinding: focusBinding,
                            focusID: ShelfFocusID(
                                row: HomeShelfRowID.affinity(shelf.descriptor.kind.identity),
                                item: item.id,
                            ),
                        )
                        .transition(itemTransition)
                    }
                }
                .transition(rowTransition)
            }
            if shelves.isEmpty, status.isFailed {
                FailedShelfNotice(title: "Picks for you", icon: "sparkles", retry: onRetry)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            sectionWidth = width
        }
    }

    private static func icon(for kind: AffinityShelfKind) -> String {
        switch kind {
        case .bucket(.person): "person.fill"
        case .bucket: "sparkles"
        case .similar: "rectangle.on.rectangle.angled"
        }
    }
}

#if DEBUG
    private struct AffinityShelvesViewPreview: View {
        private var shelves: [CachedAffinityShelf] {
            let items = (0 ..< 8).map { index in
                MediaItem(id: "m\(index)", name: "Movie \(index)", type: .movie, productionYear: 1980 + index)
            }
            return [
                CachedAffinityShelf(
                    descriptor: AffinityShelfDescriptor(
                        kind: .bucket(.genreDecade("Horror", 1980)),
                        title: "More horror from the 1980s",
                        score: 6,
                        personName: nil,
                    ),
                    items: items,
                ),
                CachedAffinityShelf(
                    descriptor: AffinityShelfDescriptor(
                        kind: .bucket(.person("p1")),
                        title: "More from Ada Lovelace",
                        score: 4,
                        personName: "Ada Lovelace",
                    ),
                    items: items,
                ),
                CachedAffinityShelf(
                    descriptor: AffinityShelfDescriptor(
                        kind: .similar(seedID: "m0", seedName: "Movie 0", wasPlayed: true),
                        title: "Because you watched Movie 0",
                        score: 3,
                        personName: nil,
                    ),
                    items: items,
                ),
            ]
        }

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                        AffinityShelvesView(
                            shelves: shelves,
                            status: .loaded,
                            menu: { _ in ShelfMenuHandlers() },
                            onRetry: {},
                        )

                        // Nothing survived: the failed notice with Retry.
                        AffinityShelvesView(
                            shelves: [],
                            status: .failed("offline"),
                            menu: { _ in ShelfMenuHandlers() },
                            onRetry: {},
                        )
                    }
                }
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        AffinityShelvesViewPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        AffinityShelvesViewPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        AffinityShelvesViewPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        AffinityShelvesViewPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        AffinityShelvesViewPreview()
    }
#endif

import DesignSystem
import JellyfinKit
import SwiftUI

/// Grid of media items within a single library, with sort/filter controls
/// and infinite scrolling
struct LibraryItemsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let library: Library

    /// Seeds the grid's sort/filter for the first load — e.g. a genre card
    /// opens this view pre-filtered to one genre. `nil` is the default
    /// unfiltered grid used by the library tabs.
    var initialQuery: LibraryQuery?

    @State private var viewModel = LibraryItemsViewModel()
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header

                LibraryFilterBar(
                    options: viewModel.visibleFilterOptions,
                    query: viewModel.query,
                    isLoadingOptions: viewModel.isLoadingFilterOptions,
                    onChange: { viewModel.update(query: $0) },
                )

                content
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .background(theme.background)
        // Width for the loaded grid's column math, measured on the container
        // top-down (frame minus the content's screen padding) — never on the
        // grid itself, which would feed the math its own output. Note this
        // write doesn't land while the sidebar-collapse transition is in
        // flight (it commits once the transition settles) — fine for the
        // loaded grid, whose content arrives later, but the reason the
        // skeleton grid must not depend on it (see `skeletonGrid`).
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width - SpacingTokens.screenPadding * 2
        } action: { width in
            gridWidth = width
        }
        .task(id: session.isConnected) {
            viewModel.attach(client: session.client, library: library, initialQuery: initialQuery)
            await viewModel.loadInitial()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpacingTokens.sm) {
            Text(viewModel.displayTitle ?? "All \(library.name)")
                .jsStyle(.headline)
                .foregroundStyle(theme.primary)

            if let countLabel = viewModel.countLabel {
                Text(countLabel)
                    .jsStyle(.caption)
                    .foregroundStyle(theme.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            skeletonGrid

        case let .failed(message):
            VStack(spacing: SpacingTokens.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.secondary)

                Text(message)
                    .jsStyle(.body)
                    .foregroundStyle(theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)

        case .empty:
            VStack(spacing: SpacingTokens.md) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.secondary)

                Text("No items match these filters")
                    .jsStyle(.body)
                    .foregroundStyle(theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)

        case .loaded:
            // The previous results stay up (dimmed) while a new query loads,
            // so menu dismissal has a stable grid to return focus through
            itemGrid
                .opacity(viewModel.isReloading ? 0.5 : 1)
        }
    }

    /// Column math lives in `PosterGridLayout`, shared with Home's Recently
    /// Added shelves so posters are the same size on both surfaces.
    private var columnLayout: (count: Int, width: CGFloat) {
        PosterGridLayout.columns(for: gridWidth)
    }

    /// Ghost mirror of `itemGrid` while the first page loads. The filter bar
    /// above stays live.
    ///
    /// Native adaptive columns, NOT `columnLayout`: geometry-change state
    /// writes don't land while the sidebar-collapse transition is in flight
    /// (they commit only once it settles), so anything `gridWidth`-driven
    /// paints a single centered column for the skeleton's entire lifetime.
    /// Adaptive columns are computed inside the layout pass itself — right on
    /// the first frame — and their math (as many ≥minimum columns as fit,
    /// stretched evenly) matches `PosterGridLayout`'s, so the real grid lands
    /// on the same lattice. The flexible `GhostCard` fills whatever cell the
    /// grid computes.
    private var skeletonGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: PosterGridLayout.minimumCardWidth),
                    spacing: SpacingTokens.cardGap,
                ),
            ],
            spacing: SpacingTokens.cardGap,
        ) {
            ForEach(0 ..< 18, id: \.self) { _ in
                GhostCard(aspectRatio: 2.0 / 3.0)
            }
        }
        .skeletonPulse()
    }

    private var itemGrid: some View {
        let layout = columnLayout
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: SpacingTokens.cardGap),
                count: layout.count,
            ),
            spacing: SpacingTokens.cardGap,
        ) {
            ForEach(viewModel.items) { item in
                item.posterShelfItem(
                    client: session.client,
                    width: layout.width,
                    menu: ShelfMenuHandlers(
                        setPlayed: { played in
                            Task { await viewModel.setPlayed(played, for: item) }
                        },
                        setFavorite: { favorite in
                            Task { await viewModel.setFavorite(favorite, for: item) }
                        },
                    ),
                )
                .onAppear {
                    viewModel.loadMoreIfNeeded(currentItem: item)
                }
            }

            if viewModel.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .gridCellColumns(1)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LibraryItemsView(
            library: Library(id: "preview-1", name: "Movies", collectionType: .movies),
        )
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

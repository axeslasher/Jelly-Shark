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
                    onChange: { viewModel.update(query: $0) },
                )

                content
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .background(theme.background)
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
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 400)

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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            gridWidth = width
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

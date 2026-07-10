import SwiftUI
import JellyfinKit
import DesignSystem

/// Grid of media items within a single library, with sort/filter controls
/// and infinite scrolling
struct LibraryItemsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let library: Library

    @State private var viewModel = LibraryItemsViewModel()
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header

                LibraryFilterBar(
                    options: viewModel.visibleFilterOptions,
                    query: viewModel.query,
                    onChange: { viewModel.update(query: $0) }
                )

                content
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .background(theme.background)
        .task(id: session.isConnected) {
            viewModel.attach(client: session.client, library: library)
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

        case .failed(let message):
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

    /// Poster cards need an explicit width, so the grid can't rely on
    /// adaptive columns (cards would float centered inside stretched
    /// columns, insetting the edges). Instead, measure the available width
    /// and size cards to exactly fill their columns, flush both edges.
    private var columnLayout: (count: Int, width: CGFloat) {
        let gap = SpacingTokens.cardGap
        let minimumCardWidth: CGFloat = 220
        guard gridWidth > minimumCardWidth else { return (1, minimumCardWidth) }
        let count = max(1, Int((gridWidth + gap) / (minimumCardWidth + gap)))
        let width = (gridWidth - gap * CGFloat(count - 1)) / CGFloat(count)
        return (count, width)
    }

    private var itemGrid: some View {
        let layout = columnLayout
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: SpacingTokens.cardGap),
                count: layout.count
            ),
            spacing: SpacingTokens.cardGap
        ) {
            ForEach(viewModel.items) { item in
                item.posterShelfItem(client: session.client, width: layout.width)
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
            library: Library(id: "preview-1", name: "Movies", collectionType: .movies)
        )
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

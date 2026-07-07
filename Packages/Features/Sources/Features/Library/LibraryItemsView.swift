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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                header

                LibraryFilterBar(
                    options: viewModel.filterOptions,
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
            Text(library.name)
                .font(theme.jsHeadline)
                .foregroundStyle(theme.primary)

            if let countLabel = viewModel.countLabel {
                Text(countLabel)
                    .font(theme.jsCaption)
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
                    .font(theme.jsBody)
                    .foregroundStyle(theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)

        case .empty:
            VStack(spacing: SpacingTokens.md) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.secondary)

                Text("No items match these filters")
                    .font(theme.jsBody)
                    .foregroundStyle(theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)

        case .loaded:
            itemGrid
        }
    }

    private var itemGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 220), spacing: SpacingTokens.cardGap)
            ],
            spacing: SpacingTokens.cardGap
        ) {
            ForEach(viewModel.items) { item in
                item.posterShelfItem(client: session.client)
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
            library: Library(id: "preview-1", name: "Movies", collectionType: .movies)
        )
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

import SwiftUI
import JellyfinKit
import DesignSystem

/// Search screen for finding media across the user's libraries
struct SearchView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @State private var viewModel = SearchViewModel()

    // No NavigationStack here: RootView owns each tab's stack (with a path
    // binding) so it can pop to root before a tab switch — see RootView's
    // `tabSelection` for the tvOS bug this works around.
    var body: some View {
        content
            .background(theme.background)
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
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            prompt
        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            message(
                icon: "magnifyingglass",
                text: "No results for \"\(viewModel.query)\""
            )
        case .failed(let errorMessage):
            message(icon: "exclamationmark.triangle.fill", text: errorMessage)
        case .results:
            resultsGrid
        }
    }

    private var prompt: some View {
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

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 340), spacing: SpacingTokens.cardGap)
                ],
                spacing: SpacingTokens.cardGap
            ) {
                ForEach(viewModel.results) { item in
                    item.landscapeShelfItem(client: session.client)
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .withThemeEnvironment()
    .environment(AppSession())
}

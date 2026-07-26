// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
            skeletonGrid
        case .empty:
            message(
                icon: "magnifyingglass",
                text: "No results for \"\(viewModel.query)\"",
            )
        case let .failed(errorMessage):
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

    /// Ghost mirror of `resultsGrid` while a search is in flight: the same
    /// adaptive columns and landscape card lockup, so results land where the
    /// ghosts were.
    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 340), spacing: SpacingTokens.cardGap),
                ],
                spacing: SpacingTokens.cardGap,
            ) {
                ForEach(0 ..< 12, id: \.self) { _ in
                    GhostCard(width: 320, aspectRatio: 16.0 / 9.0)
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .skeletonPulse()
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 340), spacing: SpacingTokens.cardGap),
                ],
                spacing: SpacingTokens.cardGap,
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

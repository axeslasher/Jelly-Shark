import SwiftUI
import JellyfinKit
import DesignSystem

/// Grid of media items within a single library
struct LibraryItemsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let library: Library

    @State private var items: [MediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: SpacingTokens.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(theme.secondary)

                    Text(errorMessage)
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                itemGrid
            }
        }
        .background(theme.background)
        .navigationTitle(library.name)
        .task {
            await loadItems()
        }
    }

    private var itemGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 220), spacing: SpacingTokens.cardGap)
                ],
                spacing: SpacingTokens.cardGap
            ) {
                ForEach(items) { item in
                    NavigationLink {
                        MediaDetailView(item: item)
                    } label: {
                        itemCard(for: item)
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
    }

    private func itemCard(for item: MediaItem) -> some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius)
            .fill(theme.surface)
            .frame(height: 300)
            .overlay {
                VStack(spacing: SpacingTokens.sm) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(theme.tertiary)

                    Text(item.name)
                        .font(.jsCaption)
                        .foregroundStyle(theme.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    if let year = item.productionYear {
                        Text(String(year))
                            .font(.jsCaption)
                            .foregroundStyle(theme.secondary)
                    }
                }
                .padding(SpacingTokens.md)
            }
    }

    private func loadItems() async {
        isLoading = true
        errorMessage = nil

        guard let client = session.client else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            isLoading = false
            return
        }

        do {
            items = try await client.getLibraryItems(libraryId: library.id, limit: 100, startIndex: nil)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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

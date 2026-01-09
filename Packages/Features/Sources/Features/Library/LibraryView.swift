import SwiftUI
import JellyfinKit
import DesignSystem

/// Library browsing screen
/// Shows all libraries and their contents
public struct LibraryView: View {
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    // Library Grid
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 300), spacing: SpacingTokens.cardGap)
                        ],
                        spacing: SpacingTokens.cardGap
                    ) {
                        ForEach(LibraryType.allCases, id: \.self) { type in
                            libraryCard(for: type)
                        }
                    }
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
                .padding(.vertical, SpacingTokens.lg)
            }
            .background(theme.background)
            .navigationTitle("Library")
        }
    }

    private func libraryCard(for type: LibraryType) -> some View {
        RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
            .fill(theme.surface)
            .frame(height: 180)
            .overlay {
                VStack(spacing: SpacingTokens.md) {
                    Image(systemName: type.icon)
                        .font(.system(size: 48))
                        .foregroundStyle(theme.accent)

                    Text(type.title)
                        .font(.jsTitle)
                        .foregroundStyle(theme.primary)

                    Text("Connect to view")
                        .font(.jsCaption)
                        .foregroundStyle(theme.tertiary)
                }
            }
    }
}

// MARK: - Library Type

extension LibraryView {
    enum LibraryType: CaseIterable {
        case movies
        case tvShows
        case music
        case collections

        var title: String {
            switch self {
            case .movies: return "Movies"
            case .tvShows: return "TV Shows"
            case .music: return "Music"
            case .collections: return "Collections"
            }
        }

        var icon: String {
            switch self {
            case .movies: return "film.fill"
            case .tvShows: return "tv.fill"
            case .music: return "music.note"
            case .collections: return "folder.fill"
            }
        }
    }
}

#Preview {
    LibraryView()
        .withThemeEnvironment()
}

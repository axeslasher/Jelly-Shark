import SwiftUI
import JellyfinKit
import DesignSystem

/// Library browsing screen
/// Shows all libraries and their contents
public struct LibraryView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var connection

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
                        if connection.state == .connected {
                            ForEach(connection.libraries) { library in
                                NavigationLink {
                                    LibraryItemsView(library: library)
                                } label: {
                                    libraryCard(for: library)
                                }
                                #if os(tvOS)
                                .buttonStyle(.borderless)
                                #else
                                .buttonStyle(.plain)
                                #endif
                            }
                        } else {
                            ForEach(LibraryType.allCases, id: \.self) { type in
                                Button(action: {}) {
                                    placeholderCard(for: type)
                                }
                                #if os(tvOS)
                                .buttonStyle(.borderless)
                                #else
                                .buttonStyle(.plain)
                                #endif
                            }
                        }
                    }
                }
                .padding(.horizontal, SpacingTokens.screenPadding)
                .padding(.vertical, SpacingTokens.lg)
            }
            .background(theme.background)
        }
    }

    @ViewBuilder
    private func libraryCard(for library: Library) -> some View {
        if let url = session.client?.imageURL(for: library) {
            ArtworkImage(url: url)
                .frame(height: 180)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: theme.background.opacity(0.85), location: 0),
                            .init(color: .clear, location: 0.6),
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                        Text(library.name)
                            .font(.jsTitle)
                            .foregroundStyle(theme.primary)

                        if let count = library.childCount {
                            Text("\(count) items")
                                .font(.jsCaption)
                                .foregroundStyle(theme.secondary)
                        }
                    }
                    .padding(SpacingTokens.md)
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge))
        } else {
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge)
                .fill(theme.surface)
                .frame(height: 180)
                .overlay {
                    VStack(spacing: SpacingTokens.md) {
                        Image(systemName: library.systemImageName)
                            .font(.system(size: 48))
                            .foregroundStyle(theme.accent)

                        Text(library.name)
                            .font(.jsTitle)
                            .foregroundStyle(theme.primary)

                        if let count = library.childCount {
                            Text("\(count) items")
                                .font(.jsCaption)
                                .foregroundStyle(theme.tertiary)
                        }
                    }
                }
        }
    }

    private func placeholderCard(for type: LibraryType) -> some View {
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
        .environment(AppSession())
        .environment(ServerConnectionViewModel())
}

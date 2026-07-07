import SwiftUI
import JellyfinKit
import DesignSystem

/// Sort and filter controls shown above a library grid.
///
/// A horizontal row of system-styled menus and buttons; every control edits
/// a copy of the query and hands it back via `onChange`. The controls keep
/// the platform's default button chrome — on tvOS that is what makes them
/// focusable with the standard lift-and-highlight treatment.
struct LibraryFilterBar: View {
    @Environment(\.theme) private var theme

    let options: LibraryFilterOptions
    let query: LibraryQuery
    let onChange: (LibraryQuery) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: SpacingTokens.sm) {
                sortMenu

                if !options.genres.isEmpty {
                    multiSelectMenu(
                        title: "Genres",
                        values: options.genres,
                        selection: query.genres,
                        label: { $0 }
                    ) { updated in
                        var next = query
                        next.genres = updated
                        onChange(next)
                    }
                }

                if !options.decades.isEmpty {
                    multiSelectMenu(
                        title: "Decades",
                        values: options.decades,
                        selection: query.decades,
                        label: { "\($0.formatted(.number.grouping(.never)))s" }
                    ) { updated in
                        var next = query
                        next.decades = updated
                        onChange(next)
                    }
                }

                watchedMenu

                favoritesToggle

                if !options.officialRatings.isEmpty {
                    multiSelectMenu(
                        title: "Ratings",
                        values: options.officialRatings,
                        selection: query.officialRatings,
                        label: { $0 }
                    ) { updated in
                        var next = query
                        next.officialRatings = updated
                        onChange(next)
                    }
                }

                if query.isFiltering {
                    resetButton
                }
            }
            // Room for the tvOS focus effect to lift without clipping
            .padding(.vertical, SpacingTokens.xs)
        }
        .scrollClipDisabled()
        #if os(tvOS)
        // Make the whole bar a focus target so it is reachable when moving
        // up from any column of the grid below
        .focusSection()
        #endif
    }

    // MARK: - Sort

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases, id: \.self) { sort in
                Button {
                    var next = query
                    if sort == query.sort {
                        next.direction = query.direction == .ascending ? .descending : .ascending
                    } else {
                        next.sort = sort
                        next.direction = sort.defaultDirection
                    }
                    onChange(next)
                } label: {
                    if sort == query.sort {
                        Label(
                            sort.displayName,
                            systemImage: query.direction == .ascending ? "chevron.up" : "chevron.down"
                        )
                    } else {
                        Text(sort.displayName)
                    }
                }
            }
        } label: {
            Label(
                "\(query.sort.displayName) \(query.direction == .ascending ? "↑" : "↓")",
                systemImage: "arrow.up.arrow.down"
            )
        }
    }

    // MARK: - Filters

    private func multiSelectMenu<Value: Hashable>(
        title: String,
        values: [Value],
        selection: Set<Value>,
        label: @escaping (Value) -> String,
        onSelect: @escaping (Set<Value>) -> Void
    ) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    var updated = selection
                    if !updated.insert(value).inserted {
                        updated.remove(value)
                    }
                    onSelect(updated)
                } label: {
                    if selection.contains(value) {
                        Label(label(value), systemImage: "checkmark")
                    } else {
                        Text(label(value))
                    }
                }
            }
        } label: {
            Text(selection.isEmpty ? title : "\(title) · \(selection.count)")
        }
    }

    private var watchedMenu: some View {
        Menu {
            ForEach(WatchedFilter.allCases, id: \.self) { filter in
                Button {
                    var next = query
                    next.watched = filter
                    onChange(next)
                } label: {
                    if filter == query.watched {
                        Label(filter.displayName, systemImage: "checkmark")
                    } else {
                        Text(filter.displayName)
                    }
                }
            }
        } label: {
            Text(query.watched == .any ? "Watched" : query.watched.displayName)
        }
    }

    private var favoritesToggle: some View {
        Button {
            var next = query
            next.favoritesOnly.toggle()
            onChange(next)
        } label: {
            Label("Favorites", systemImage: query.favoritesOnly ? "heart.fill" : "heart")
        }
    }

    private var resetButton: some View {
        Button {
            onChange(query.withFiltersCleared)
        } label: {
            Label("Reset", systemImage: "xmark")
        }
    }
}

// MARK: - Display Names

extension LibrarySort {
    var displayName: String {
        switch self {
        case .name: return "Alphabetical"
        case .releaseDate: return "Release Date"
        case .dateAdded: return "Date Added"
        case .communityRating: return "Community Rating"
        case .criticRating: return "Critic Rating"
        }
    }

    /// The direction people expect when first picking this sort
    var defaultDirection: LibrarySortDirection {
        self == .name ? .ascending : .descending
    }
}

extension WatchedFilter {
    var displayName: String {
        switch self {
        case .any: return "Any"
        case .unplayed: return "Unwatched"
        case .played: return "Watched"
        }
    }
}

#Preview {
    LibraryFilterBar(
        options: LibraryFilterOptions(
            genres: ["Action", "Comedy", "Horror"],
            officialRatings: ["PG", "PG-13", "R"],
            years: [1985, 1994, 2003, 2021]
        ),
        query: LibraryQuery(genres: ["Horror"], favoritesOnly: true),
        onChange: { _ in }
    )
    .padding()
    .withThemeEnvironment()
}

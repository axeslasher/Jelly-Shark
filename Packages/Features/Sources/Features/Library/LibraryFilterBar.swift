import SwiftUI
import JellyfinKit
import DesignSystem

/// Sort and filter controls shown above a library grid.
///
/// A horizontal row of system-styled menus and buttons; every control edits
/// a copy of the query and hands it back via `onChange`. The controls keep
/// the platform's default button chrome — on tvOS that is what makes them
/// focusable with the standard lift-and-highlight treatment.
///
/// TODO: Replace the system `Menu`s with a custom dropdown overlay. tvOS
/// menu dismissal leaves focus in limbo for ~1.5s before it returns to the
/// bar (inherent to the system presentation — it is not load- or
/// re-render-related). Owning the presentation gives us instant focus
/// restore, plus full row styling: trailing accent checkmarks and themed
/// typography inside the dropdown.
struct LibraryFilterBar: View {
    @Environment(\.theme) private var theme

    let options: LibraryFilterOptions
    let query: LibraryQuery
    let onChange: (LibraryQuery) -> Void

    var body: some View {
        // On tvOS the pills sit in a plain HStack: nesting them in a
        // horizontal ScrollView slowed the focus engine's return to the bar
        // after a menu dismissal, and the pills fit on screen anyway
        #if os(tvOS)
        themedPillRow
            // Make the whole bar a focus target so it is reachable when
            // moving up from any column of the grid below
            .focusSection()
        #else
        ScrollView(.horizontal) {
            themedPillRow
        }
        .scrollClipDisabled()
        #endif
    }

    /// Themes with a `focusFill` swap the pills onto ``ThemedGlassButtonStyle``
    /// so the focus platter takes the theme's hue (the default system chrome
    /// always lifts to white). `.menuStyle(.button)` routes the Menu pills
    /// through the same button styling as the plain Buttons.
    @ViewBuilder
    private var themedPillRow: some View {
        #if os(macOS)
        pillRow
        #else
        if let fill = theme.focusFill {
            pillRow
                .menuStyle(.button)
                .buttonStyle(ThemedGlassButtonStyle(tint: fill))
        } else {
            pillRow
        }
        #endif
    }

    private var pillRow: some View {
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
                clearButton
            }
        }
        // Room for the tvOS focus effect to lift without clipping
        .padding(.vertical, SpacingTokens.xs)
        // NOTE: no .tint here — on tvOS it repaints the button chrome
        // itself, drowning the pill labels in accent color
        .font(theme.jsTitle)
    }

    // MARK: - Sort

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases, id: \.self) { sort in
                let isActive = sort == query.sort
                // Toggles render the system selection checkmark; "turning
                // off" the active sort reads as flipping its direction
                Toggle(
                    sort.phrase(for: isActive ? query.direction : sort.defaultDirection),
                    isOn: Binding(
                        get: { isActive },
                        set: { _ in
                            var next = query
                            if isActive {
                                next.direction = query.direction == .ascending ? .descending : .ascending
                            } else {
                                next.sort = sort
                                next.direction = sort.defaultDirection
                            }
                            onChange(next)
                        }
                    )
                )
                // Scoped to the dropdown row, where tint only colors the
                // selection indicator
                .tint(theme.accent)
            }
        } label: {
            Label(query.sort.phrase(for: query.direction), systemImage: "arrow.up.arrow.down")
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
                // Toggles get the system selection checkmark, which is the
                // only selected-state treatment tvOS menus render reliably
                Toggle(
                    label(value),
                    isOn: Binding(
                        get: { selection.contains(value) },
                        set: { isOn in
                            var updated = selection
                            if isOn {
                                updated.insert(value)
                            } else {
                                updated.remove(value)
                            }
                            onSelect(updated)
                        }
                    )
                )
                .tint(theme.accent)
            }
        } label: {
            countedPillLabel(title, count: selection.count)
        }
    }

    private var watchedMenu: some View {
        Menu {
            Picker("Status", selection: Binding(
                get: { query.watched },
                set: { selected in
                    var next = query
                    next.watched = selected
                    onChange(next)
                }
            )) {
                ForEach(WatchedFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .tint(theme.accent)
        } label: {
            Text(query.watched == .any ? "Status" : query.watched.displayName)
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

    private var clearButton: some View {
        Button {
            onChange(query.withFiltersCleared)
        } label: {
            Label("Clear", systemImage: "x.circle.fill")
        }
    }

    // MARK: - Shared Labels

    /// A pill title with an accent-colored badge counting active selections
    private func countedPillLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: SpacingTokens.xs) {
            Text(title)
            if count > 0 {
                Text("\(count)")
                    .font(theme.js(.caption, .strong))
                    .foregroundStyle(theme.primary)
                    .padding(SpacingTokens.xxs)
                    .frame(minWidth: 32, minHeight: 32)
                    .background(Circle().fill(theme.accent))
            }
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

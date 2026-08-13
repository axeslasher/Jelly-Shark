import DesignSystem
import JellyfinKit
import SwiftUI

/// Cast & Crew shelf. Renders nothing when there are no people. The client is
/// only needed for headshot URLs, so a clientless session (previews) still
/// renders the shelf with placeholder artwork.
struct CastShelfSection: View {
    @Environment(AppSession.self) private var session

    let people: [CastMember]
    /// Whether the below-the-fold focus region owns focus (from the owner's
    /// region tracking). The rising edge steers first focus onto the first cast
    /// card — see `steersFirstFocus`.
    let isRegionFocused: Bool
    /// Whether cast is the first focusable section (no episodes / collection
    /// ahead of it). Only then does it steer first focus; on series and
    /// collection pages the leading section steers its own, and this stays off
    /// so the two steers are mutually exclusive.
    let steersFirstFocus: Bool

    /// Which cast card owns focus; set once on region entry to correct the
    /// focus engine's tendency to skip cast for More Like This.
    @FocusState private var focusedCastId: String?

    /// One-shot: after the first steer, later hero→shelves re-entries let the
    /// engine restore the last-focused card instead of re-yanking to the first.
    @State private var hasSteered = false

    var body: some View {
        if !people.isEmpty {
            ContentShelf("Cast & Crew", icon: "person.2.fill") {
                ForEach(people) { member in
                    // People without a real server id can't be fetched, so
                    // their cards keep the focus lift but don't navigate.
                    Group {
                        if member.hasServerId {
                            CastCard(
                                url: session.client?.headshotURL(for: member),
                                name: member.name,
                                role: member.role ?? member.kind,
                                value: member,
                            )
                        } else {
                            CastCard(
                                url: session.client?.headshotURL(for: member),
                                name: member.name,
                                role: member.role ?? member.kind,
                            )
                        }
                    }
                    .focused($focusedCastId, equals: member.id)
                }
            }
            .onChange(of: isRegionFocused) { _, entered in
                guard entered, steersFirstFocus, !hasSteered, let first = people.first else { return }
                focusedCastId = first.id
                hasSteered = true
            }
        }
    }
}

/// Collection contents shelf for BoxSet pages — the movies inside the
/// collection, in release order. Renders nothing until they arrive.
struct CollectionItemsSection: View {
    @Environment(AppSession.self) private var session

    let items: [MediaItem]

    var body: some View {
        if !items.isEmpty {
            ContentShelf("In This Collection", icon: "film.stack.fill") {
                ForEach(items) { item in
                    // The collection IS this page's content (like episodes on
                    // a series page), so its posters render a step larger
                    // than the supporting shelves' 200pt cards.
                    item.posterShelfItem(client: session.client, width: 316)
                }
            }
        }
    }
}

/// More Like This shelf. Renders nothing until similar items arrive.
struct SimilarItemsSection: View {
    @Environment(AppSession.self) private var session

    let items: [MediaItem]

    var body: some View {
        if !items.isEmpty {
            ContentShelf("More Like This", icon: "rectangle.stack.fill") {
                ForEach(items) { item in
                    item.posterShelfItem(client: session.client)
                }
            }
        }
    }
}

/// "Browse by Genre" shelf — the page item's own genres, each handing off to a
/// genre-filtered grid. Where More Like This offers the server's pick of kin
/// titles, this offers the whole vibe: the path outward when neither this page
/// nor its neighbours was it. Renders nothing for an item with no genres.
struct GenreShelfSection: View {
    /// How many tiles the shelf shows, measured against a real library (583
    /// movies, 59 series) rather than guessed: a cap of 5 leaves 99% of movies
    /// and 80% of series whole, where a cap of 3 would truncate 44% of series.
    /// One cap for both page types on purpose — a shelf that behaves
    /// differently depending on which page it's on is a rule nobody remembers.
    private static let maxGenres = 5

    let genres: [String]

    /// The first five in server order. Jellyfin exposes no genre weighting, and
    /// sorting alphabetically measured *worse*: on the worst case in the sample
    /// (an 11-genre show) it surfaced the five most generic labels the item had
    /// and none of the ones that describe it.
    private var shownGenres: [String] {
        Array(genres.prefix(Self.maxGenres))
    }

    var body: some View {
        if !shownGenres.isEmpty {
            // No library name in the title, unlike Home's "Browse {library} by
            // genre": these cards aren't scoped to one, so naming one would be
            // a claim the destination doesn't honour.
            ContentShelf("Browse by Genre", icon: "theatermasks.fill") {
                ForEach(shownGenres, id: \.self) { genre in
                    // Unscoped deliberately (#108): from a detail page "more
                    // Horror" means everything in the collection, not one
                    // library — and a detail page has no library to resolve to
                    // anyway. The grid still offers the Library pill to narrow.
                    GenreCardView(library: nil, genre: genre)
                }
            }
        }
    }
}

#if DEBUG
    private struct CastShelfSectionPreview: View {
        var body: some View {
            // The stack hosts the cast cards' value-based links; without one
            // they render disabled.
            NavigationStack {
                ScrollView {
                    CastShelfSection(
                        people: PreviewData.cast,
                        isRegionFocused: false,
                        steersFirstFocus: false,
                    )
                }
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        CastShelfSectionPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        CastShelfSectionPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        CastShelfSectionPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        CastShelfSectionPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        CastShelfSectionPreview()
    }
#endif

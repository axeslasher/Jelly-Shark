import DesignSystem
import JellyfinKit
import SwiftUI

/// Cast & Crew shelf. Renders nothing when there's no client or no people.
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
        if let client = session.client, !people.isEmpty {
            ContentShelf("Cast & Crew", icon: "person.2.fill") {
                ForEach(people) { member in
                    // People without a real server id can't be fetched, so
                    // their cards keep the focus lift but don't navigate.
                    Group {
                        if member.hasServerId {
                            CastCard(
                                url: client.headshotURL(for: member),
                                name: member.name,
                                role: member.role ?? member.kind,
                                value: member,
                            )
                        } else {
                            CastCard(
                                url: client.headshotURL(for: member),
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

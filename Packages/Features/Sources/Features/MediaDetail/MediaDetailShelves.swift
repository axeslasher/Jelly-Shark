import DesignSystem
import JellyfinKit
import SwiftUI

/// Cast & Crew shelf. Renders nothing when there's no client or no people.
struct CastShelfSection: View {
    @Environment(AppSession.self) private var session

    let people: [CastMember]

    var body: some View {
        if let client = session.client, !people.isEmpty {
            ContentShelf("Cast & Crew", icon: "person.2.fill") {
                ForEach(people) { member in
                    // People without a real server id can't be fetched, so
                    // their cards keep the focus lift but don't navigate.
                    if member.hasServerId {
                        CastCard(
                            url: client.headshotURL(for: member),
                            name: member.name,
                            role: member.role ?? member.kind,
                            value: member
                        )
                    } else {
                        CastCard(
                            url: client.headshotURL(for: member),
                            name: member.name,
                            role: member.role ?? member.kind
                        )
                    }
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

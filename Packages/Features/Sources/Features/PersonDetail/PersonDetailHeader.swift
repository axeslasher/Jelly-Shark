import DesignSystem
import JellyfinKit
import SwiftUI

/// The person page's top lockup: circular headshot (with a favorite toggle
/// beneath it) on the left; name, life-facts metadata, and biography on the
/// right.
///
/// The passed-in `member` stub renders the name and headshot instantly; the
/// detailed `person` fetch fills in the metadata line and biography when it
/// lands. Treatments mirror the media detail hero: the name uses the hero
/// title style, the metadata row the `MediaMetadataRow` styling, and the
/// biography is an `OverviewLabel` inside a `.plain` button that reveals the
/// full text in an `OverviewOverlay`.
struct PersonDetailHeader: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let member: CastMember
    let person: Person?
    @Binding var isPresentingBiography: Bool

    /// Optimistic local override for the favorite toggle. While `nil`, the
    /// button reflects Jellyfin's fetched state; a tap sets the override
    /// immediately and is cleared/reverted based on the server response.
    @State private var favoriteOverride: Bool?

    /// Measured height of the headshot column, mirrored onto the info column
    /// as a minimum so its focus section always spans the favorite button's
    /// horizontal band (see `body`).
    @State private var headshotColumnHeight: CGFloat = 0

    /// Hero-scale circle diameter — a clear jump from the 200pt row cards.
    private static let headshotSize: CGFloat = 300

    /// Favorite state shown by the button: optimistic value if any, otherwise
    /// Jellyfin's stored status.
    private var isFavorite: Bool {
        favoriteOverride ?? person?.isFavorite ?? false
    }

    var body: some View {
        // Both columns are focus sections so directional moves target the
        // whole column frame, not just its focusables' frames. Without this a
        // short bio strands focus: the bio button's frame ends above the
        // favorite button's horizontal band, so a right-press from the heart
        // has nothing to project onto. The info column also adopts the
        // headshot column's measured height as its minimum so its section
        // always overlaps the favorite button's band — the bio button itself
        // keeps hugging its text.
        HStack(alignment: .top, spacing: SpacingTokens.xl) {
            VStack(spacing: SpacingTokens.md) {
                // Fetched at 2x the display size so 4K panels aren't upscaling.
                ArtworkImage(
                    url: session.client?.headshotURL(for: member, maxWidth: 600),
                    blurHash: person?.primaryBlurHash,
                    placeholderIcon: "person.fill"
                )
                .frame(width: Self.headshotSize, height: Self.headshotSize)
                .clipShape(Circle())

                CircleActionButton(
                    systemImage: isFavorite ? "heart.fill" : "heart",
                    title: isFavorite ? "Favorited" : "Favorite",
                    tint: isFavorite ? theme.accent : theme.primary,
                    focusedTint: isFavorite ? theme.accent : nil,
                    isEnabled: session.client != nil
                ) {
                    Task { await toggleFavorite() }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                headshotColumnHeight = height
            }
            #if os(tvOS)
            .focusSection()
            #endif

            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                Text(member.name)
                    .font(theme.jsDisplay)
                    .foregroundStyle(theme.primary)
                    .lineLimit(2)

                metadataRow

                if let biography = person?.biography, !biography.isEmpty {
                    Button {
                        isPresentingBiography = true
                    } label: {
                        OverviewLabel(
                            tagline: nil,
                            overview: biography,
                            overviewLineLimit: 6
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, minHeight: headshotColumnHeight, alignment: .topLeading)
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    /// Life facts as an inline icon row, styled identically to the media
    /// detail's `MediaMetadataRow`: birth date with current age while living
    /// (a birth–death span otherwise), then the birthplace. Renders nothing
    /// until the detailed fetch lands or when no facts are known.
    @ViewBuilder
    private var metadataRow: some View {
        if lifeDatesText != nil || person?.birthPlace != nil {
            HStack(alignment: .center, spacing: SpacingTokens.md) {
                if let lifeDatesText {
                    Label(lifeDatesText, systemImage: "calendar")
                }
                if let place = person?.birthPlace {
                    Label(place, systemImage: "mappin.and.ellipse")
                }
            }
            .font(theme.jsBody)
            .foregroundStyle(theme.tertiary)
            .fontWeight(.bold)
            .labelStyle(MetadataLabelStyle(spacing: SpacingTokens.xs))
        }
    }

    private var lifeDatesText: String? {
        guard let person, let born = person.formattedBirthDate else { return nil }
        if let died = person.formattedDeathDate {
            return "\(born) – \(died)"
        }
        let age = person.age.map { " (age \($0))" } ?? ""
        return "Born \(born)\(age)"
    }

    /// Optimistically flip the favorite state, then persist; revert on failure.
    /// Person IDs are item IDs, so the standard favorite endpoints apply.
    private func toggleFavorite() async {
        guard let client = session.client else { return }
        let target = !isFavorite
        withAnimation(theme.animation) { favoriteOverride = target }
        do {
            if target {
                try await client.markFavorite(itemId: member.id)
            } else {
                try await client.unmarkFavorite(itemId: member.id)
            }
        } catch {
            withAnimation(theme.animation) { favoriteOverride = !target }
        }
    }
}

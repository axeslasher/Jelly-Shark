import DesignSystem
import JellyfinKit
import SwiftUI

/// The person page's top lockup: circular headshot on the left; name,
/// birth/place metadata, and biography on the right.
///
/// The passed-in `member` stub renders the name and headshot instantly; the
/// detailed `person` fetch fills in the metadata line and biography when it
/// lands. Text styles mirror the media detail hero: the name uses the hero
/// title treatment, the metadata line the tagline treatment, and the biography
/// the overview treatment.
struct PersonDetailHeader: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let member: CastMember
    let person: Person?

    /// Hero-scale circle diameter — a clear jump from the 200pt row cards.
    private static let headshotSize: CGFloat = 400

    var body: some View {
        HStack(alignment: .top, spacing: SpacingTokens.xl) {
            // Fetched at 2x the display size so 4K panels aren't upscaling.
            ArtworkImage(
                url: session.client?.headshotURL(for: member, maxWidth: 800),
                blurHash: person?.primaryBlurHash,
                placeholderIcon: "person.fill"
            )
            .frame(width: Self.headshotSize, height: Self.headshotSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                Text(member.name)
                    .font(theme.jsDisplay)
                    .foregroundStyle(theme.primary)
                    .lineLimit(2)

                if let metadata = metadataText {
                    Text(metadata)
                        .font(theme.jsHeadline)
                        .foregroundStyle(theme.primary)
                }

                if let biography = person?.biography, !biography.isEmpty {
                    Text(biography)
                        .font(theme.jsOverview)
                        .foregroundStyle(theme.secondary)
                        .lineSpacing(4)
                        .lineLimit(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Life facts joined with the metadata-row separator: birth date with
    /// current age while living, a birth–death span otherwise, then the
    /// birthplace. Nil when no facts are known, so the line disappears
    /// entirely and the biography slides up under the name.
    private var metadataText: String? {
        guard let person else { return nil }

        var parts: [String] = []
        if let born = person.formattedBirthDate {
            if let died = person.formattedDeathDate {
                parts.append("\(born) – \(died)")
            } else {
                let age = person.age.map { " (age \($0))" } ?? ""
                parts.append("Born \(born)\(age)")
            }
        }
        if let place = person.birthPlace {
            parts.append(place)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

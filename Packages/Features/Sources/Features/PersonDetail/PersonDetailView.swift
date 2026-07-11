import DesignSystem
import JellyfinKit
import SwiftUI

/// Detail view for a person, pushed from a media detail's Cast & Crew row.
///
/// A header lockup (headshot, name, life facts, biography) over three
/// filmography shelves — movies, series, and episodes featuring the person.
/// The page has no hero of its own, so the backdrop of a random movie or
/// series from the filmography renders behind it, pinned at the media detail's
/// fully-scrolled treatment (dimmed, blurred wash) rather than tracking the
/// scroll.
public struct PersonDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let member: CastMember

    /// Detailed fetch; upgrades the header's metadata and biography.
    @State private var person: Person?
    @State private var movies: [MediaItem] = []
    @State private var series: [MediaItem] = []
    @State private var episodes: [MediaItem] = []

    /// Random filmography entry with a usable backdrop; drives the background.
    @State private var backdropItem: MediaItem?

    /// The episode currently being played, driving the player cover.
    @State private var playbackItem: MediaItem?

    /// Whether the full biography is presented in its reading overlay.
    @State private var isPresentingBiography = false

    /// Items fetched per shelf: a few pages of horizontal scrolling without
    /// pagination, and three light queries per page load.
    private static let shelfLimit = 25

    public init(member: CastMember) {
        self.member = member
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                PersonDetailHeader(
                    member: member,
                    person: person,
                    isPresentingBiography: $isPresentingBiography,
                )
                .padding(.horizontal, SpacingTokens.screenPadding)
                // The header isn't a viewport-tall hero; inset it from the
                // top edge so the lockup breathes.
                .padding(.top, SpacingTokens.xxl)

                // One focus region for all shelves so tvOS treats them as a
                // single page — moving between rows doesn't nudge the offset
                // per row (same rationale as the media detail shelves).
                VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                    PersonShelfSection(
                        title: "Movies", icon: "film.fill",
                        items: movies, style: .poster,
                        playbackItem: $playbackItem,
                    )
                    PersonShelfSection(
                        title: "TV Series", icon: "tv.fill",
                        items: series, style: .poster,
                        playbackItem: $playbackItem,
                    )
                    PersonShelfSection(
                        title: "Episodes", icon: "play.tv",
                        items: episodes, style: .episode,
                        playbackItem: $playbackItem,
                    )
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            .padding(.bottom, SpacingTokens.md)
        }
        .background(alignment: .top) { background }
        .background(theme.background)
        .task(id: member.id) {
            await loadContent()
        }
        .fullScreenCover(item: $playbackItem) { target in
            if let client = session.client {
                PlaybackContainerView(client: client, item: target)
            }
        }
        .fullScreenCover(isPresented: $isPresentingBiography) {
            biographyOverlay
        }
    }

    /// The biography's full-screen reading view — the same overlay the media
    /// detail uses for its overview, over the borrowed filmography backdrop.
    private var biographyOverlay: OverviewOverlay {
        OverviewOverlay(
            tagline: nil,
            overview: person?.biography,
            backdropURL: backdropItem.flatMap { session.client?.backdropURL(for: $0) },
        )
    }

    /// The borrowed backdrop, pinned at `progress: 1` — the media detail's
    /// fully-scrolled destination state (melt gone, dimmed, blurred).
    @ViewBuilder
    private var background: some View {
        if let client = session.client,
           let backdropItem,
           let url = client.backdropURL(for: backdropItem)
        {
            MediaDetailHeroBackdrop(
                url: url,
                blurHash: backdropItem.backdropBlurHash,
                progress: 1,
            )
        }
    }

    // MARK: - Data

    private func loadContent() async {
        guard let client = session.client, member.hasServerId else { return }

        async let personFetch = client.getPerson(personId: member.id)
        async let moviesFetch = client.getItemsFeaturingPerson(
            personId: member.id, itemTypes: [.movie], personTypes: nil, limit: Self.shelfLimit,
        )
        async let seriesFetch = client.getItemsFeaturingPerson(
            personId: member.id, itemTypes: [.series], personTypes: nil, limit: Self.shelfLimit,
        )
        async let episodesFetch = client.getItemsFeaturingPerson(
            personId: member.id, itemTypes: [.episode], personTypes: nil, limit: Self.shelfLimit,
        )

        // Failures degrade gracefully: keep the stub header, hide the shelf.
        person = try? await personFetch
        movies = await ((try? moviesFetch)) ?? []
        series = await ((try? seriesFetch)) ?? []
        episodes = await ((try? episodesFetch)) ?? []

        // Person items rarely carry a backdrop of their own; borrow one from
        // the filmography. `backdropURL(for:)` handles backdrop → thumb →
        // ancestor fallbacks, so the filter matches what would actually render.
        backdropItem = (movies + series)
            .filter { client.backdropURL(for: $0) != nil }
            .randomElement()
    }
}

#Preview {
    NavigationStack {
        PersonDetailView(
            member: CastMember(
                id: "preview-person",
                name: "Boris Karloff",
                role: "The Monster",
                kind: "Actor",
            ),
        )
    }
    .environment(AppSession())
}

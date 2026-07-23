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

    /// Owns the person and filmography fetches and their status; this view
    /// keeps only presentation state (playback cover, biography overlay).
    @State private var viewModel = PersonDetailViewModel()

    /// The episode currently being played, driving the player cover.
    @State private var playbackItem: MediaItem?

    /// Whether the full biography is presented in its reading overlay.
    @State private var isPresentingBiography = false

    public init(member: CastMember) {
        self.member = member
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.sectionSpacing) {
                PersonDetailHeader(
                    member: member,
                    viewModel: viewModel,
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
                    // The filmography is the page's body: when the load left
                    // nothing to show, degrade in place — the stub header
                    // stays, the notice sits where the shelves would, and its
                    // Retry button keeps this focus region reachable.
                    if viewModel.filmographyStatus.isFailed {
                        FailedShelfNotice(
                            message: "Couldn't load filmography — check your connection",
                            retry: { Task { await viewModel.retry() } },
                        )
                    } else {
                        PersonShelfSection(
                            title: "Movies", icon: "film.fill",
                            items: viewModel.movies, style: .poster,
                            playbackItem: $playbackItem,
                        )
                        PersonShelfSection(
                            title: "TV Series", icon: "tv.fill",
                            items: viewModel.series, style: .poster,
                            playbackItem: $playbackItem,
                        )
                        PersonShelfSection(
                            title: "Episodes", icon: "play.tv",
                            items: viewModel.episodes, style: .episode,
                            playbackItem: $playbackItem,
                        )
                    }
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
            viewModel.attach(client: session.client, member: member)
            await viewModel.load()
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
            overview: viewModel.person?.biography,
            backdropURL: viewModel.backdropItem.flatMap { session.client?.backdropURL(for: $0) },
        )
    }

    /// The borrowed backdrop, pinned at `progress: 1` — the media detail's
    /// fully-scrolled destination state (melt gone, dimmed, blurred).
    @ViewBuilder
    private var background: some View {
        if let client = session.client,
           let backdropItem = viewModel.backdropItem,
           let url = client.backdropURL(for: backdropItem)
        {
            MediaDetailHeroBackdrop(
                url: url,
                blurHash: backdropItem.backdropBlurHash,
                progress: 1,
            )
        }
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

import DesignSystem
import JellyfinKit
import SwiftUI

/// The above-the-fold lockup: title treatment, actions, overview, metadata, and
/// credits. The optimistic watched/favorite state lives on the view model (so
/// its revert-on-failure path is testable); inputs stay narrow values, bindings,
/// and the stable view-model reference — no closure inputs — so SwiftUI can
/// skip this body during scroll.
struct MediaDetailHeroSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(\.pushMediaDetail) private var pushMediaDetail

    /// Owns the watched/favorite toggles' optimistic state and server calls.
    let viewModel: MediaDetailViewModel
    let item: MediaItem
    let directors: [CastMember]
    let topCast: [CastMember]
    /// Replaces the item's own year in the metadata row when the owner can
    /// compute a better one — collection pages pass the span of their
    /// contents' release years ("1984–2024"). Nil falls back to the item's.
    let yearSpanOverride: String?
    /// Play-button title, computed by the owner ("Play", "Resume", "Replay",
    /// "Resume S2E4" on series pages)
    let playTitle: String
    /// SF Symbol for the Play button, computed by the owner alongside the
    /// title — "play.fill" for Play/Resume, "arrow.counterclockwise" for Replay.
    let playIcon: String
    /// What the Play button plays — nil (button disabled) while a series page
    /// hasn't resolved its playable episode yet
    let playTarget: MediaItem?
    @Binding var playbackItem: MediaItem?
    @Binding var isPresentingOverview: Bool

    /// Watched state shown by the button: the view model's pending optimistic
    /// value if any, otherwise Jellyfin's stored status for this item.
    private var isPlayed: Bool {
        viewModel.heroIsPlayed
    }

    /// Favorite state shown by the button: optimistic value if any, otherwise
    /// Jellyfin's stored status.
    private var isFavorite: Bool {
        viewModel.heroIsFavorite
    }

    /// Up to three genres as a single subdued line ("Crime · Drama · Thriller")
    private var genreLine: String? {
        guard let genres = item.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).joined(separator: " · ")
    }

    /// Episode pages wear their position in the show as an eyebrow directly
    /// over the episode title in the overview lockup — "Season 2 · Episode 4"
    /// in the credits column's label treatment. Nil (renders nothing) for
    /// every other type.
    private var episodeEyebrow: String? {
        item.seasonEpisodeText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.lg) {
            titleTreatment

            HStack(alignment: .top, spacing: SpacingTokens.xl) {
                VStack(alignment: .leading, spacing: SpacingTokens.md) {
                    HStack(alignment: .top, spacing: SpacingTokens.sm) {
                        playButton
                        secondaryActions
                    }
                }
                VStack(alignment: .leading, spacing: SpacingTokens.md) {
                    if item.overview != nil || heroTagline != nil || episodeEyebrow != nil {
                        overviewSection
                    }
                    MediaMetadataRow(
                        yearText: yearSpanOverride ?? item.yearSpanText,
                        // Series and collections carry no meaningful single
                        // runtime; their content count is the "how much"
                        // figure instead.
                        runtime: item.type == .series || item.type == .boxSet ? nil : item.formattedRuntime,
                        seasons: item.seasonCountText ?? item.collectionCountText,
                        seasonsIcon: item.type == .boxSet ? "film.stack" : "square.stack",
                        communityRating: item.communityRating,
                        criticRating: item.criticRating,
                        certificate: item.officialRating,
                        resolution: item.technicalInfo?.resolution,
                        videoRange: item.technicalInfo?.videoRange,
                        audioFormat: item.technicalInfo?.audioFormat,
                    )
                    if let genreLine {
                        Text(genreLine)
                            .jsStyle(.caption, .emphasized)
                            .foregroundStyle(theme.tertiary)
                            .lineLimit(1)
                    }
                }
                CreditsColumn(
                    directorNames: directors.map(\.name),
                    castNames: topCast.map(\.name),
                )
                .frame(width: 250)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, SpacingTokens.md)
        // Animate exactly the toggle-driven updates (button icons/labels, the
        // owner's Play label) — the moved-to-view-model equivalent of the old
        // `withAnimation` around each optimistic flip.
        .animation(theme.animation, value: viewModel.heroPlayedOverride)
        .animation(theme.animation, value: viewModel.heroFavoriteOverride)
        // Reserve a full viewport-height hero and pin the content to the bottom.
        // Anchoring (rather than pushing down with a Spacer) keeps the action row /
        // overview / credits on the same baseline for every item — the logo or
        // title fallback grows upward into the backdrop instead of shoving the rest
        // of the lockup around. Tuning: drop `.vertical` to a fraction via the
        // closure form (e.g. `.containerRelativeFrame(.vertical) { h, _ in h * 0.85 }`)
        // for a shorter hero, or change `.bottom` padding above to lift the lockup.
        .containerRelativeFrame(.vertical, alignment: .bottomLeading)
    }

    /// The item's logo if one exists, falling back to the title text. Rendered
    /// with `TrimmedLogoImage` (not `ArtworkImage`) so the logo's transparency
    /// is preserved instead of being boxed in by a surface-colored base — and
    /// its transparent margins are cropped away, so every logo sits flush
    /// against the box's bottom-left corner instead of floating on whatever
    /// padding the artwork baked in.
    ///
    /// Episode pages keep the inherited series logo — the lockup reads as the
    /// show (the eyebrow places the episode in it, and the episode's own name
    /// headlines the overview).
    @ViewBuilder
    private var titleTreatment: some View {
        if let client = session.client, let url = client.logoURL(for: item) {
            TrimmedLogoImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    // Fixed box reserves a consistent logo footprint for every
                    // item; scaledToFit letterboxes the logo inside it and
                    // bottomLeading pins it so the content below never shifts.
                    .frame(width: 480, height: 280, alignment: .bottomLeading)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
            } fallback: {
                titleText
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        // An episode lockup still reads as the show when the series logo is
        // missing — the series name, not the episode title (that headlines
        // the overview). Mirrors the Home hero.
        Text(item.type == .episode ? (item.seriesName ?? item.name) : item.name)
            .jsStyle(.display)
            .foregroundStyle(theme.primary)
    }

    private var playButton: some View {
        Button {
            playbackItem = playTarget
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: playIcon)
                Text(playTitle)
            }
            .jsStyle(.headline)
        }
        .glassButtonStyle(tint: theme.focusFill)
        .disabled(session.client == nil || playTarget == nil)
    }

    /// Secondary actions beneath Play: icon-only circular toggles for watched
    /// state and favorite. Each reveals its label beneath the circle while
    /// focused. Both flip optimistically and revert if the server call fails.
    private var secondaryActions: some View {
        HStack(alignment: .top, spacing: SpacingTokens.sm) {
            // Active states keep their accent tint through focus (nil falls
            // back to the on-platter color), so "already watched/favorited"
            // stays legible while the button is lifted.
            CircleActionButton(
                systemImage: isPlayed ? "checkmark" : "eye.fill",
                title: isPlayed ? "Watched" : "Mark Watched",
                tint: isPlayed ? theme.accent : theme.primary,
                focusedTint: isPlayed ? theme.accent : nil,
                isEnabled: session.client != nil,
            ) {
                Task { await viewModel.toggleHeroPlayed() }
            }

            CircleActionButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                title: isFavorite ? "Favorited" : "Favorite",
                tint: isFavorite ? theme.accent : theme.primary,
                focusedTint: isFavorite ? theme.accent : nil,
                isEnabled: session.client != nil,
            ) {
                Task { await viewModel.toggleHeroFavorite() }
            }

            // The path up from an episode to its show — disabled until the
            // view model's series fetch lands (the pushed page needs a real
            // series item, not a synthesized stub).
            if item.type == .episode {
                CircleActionButton(
                    systemImage: "square.stack",
                    title: "Go to Series",
                    tint: theme.primary,
                    isEnabled: viewModel.seriesItem != nil,
                ) {
                    if let series = viewModel.seriesItem {
                        pushMediaDetail?(series)
                    }
                }
            }
        }
    }

    /// What headlines the overview in the tagline slot: episodes put their
    /// own title there (the lockup above reads as the show, so this is where
    /// the viewer learns WHICH episode this page is); everything else keeps
    /// its marketing tagline.
    private var heroTagline: String? {
        item.type == .episode ? item.name : item.tagline
    }

    /// Truncated overview. The description truncates on
    /// the page and lives in a `.plain` Button that reveals the full text in a
    /// full-screen overlay.
    private var overviewSection: some View {
        Button {
            isPresentingOverview = true
        } label: {
            OverviewLabel(eyebrow: episodeEyebrow, tagline: heroTagline, overview: item.overview)
        }
        .plainFocusButtonStyle(tint: theme.focusFill, cornerRadius: theme.cornerRadiusLarge)
    }
}

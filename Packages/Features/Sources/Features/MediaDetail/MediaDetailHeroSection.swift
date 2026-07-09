import DesignSystem
import JellyfinKit
import SwiftUI

/// The above-the-fold lockup: title treatment, actions, overview, metadata, and
/// credits. Owns the optimistic watched/favorite state — it's purely hero-local
/// UI state, and keeping it here (with narrow value/binding inputs and no closure
/// inputs) lets SwiftUI skip this body during scroll.
struct MediaDetailHeroSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let item: MediaItem
    let directors: [CastMember]
    let topCast: [CastMember]
    /// Play-button title, computed by the owner ("Play", "Resume",
    /// "Resume S2E4" on series pages)
    let playTitle: String
    /// What the Play button plays — nil (button disabled) while a series page
    /// hasn't resolved its playable episode yet
    let playTarget: MediaItem?
    @Binding var playbackItem: MediaItem?
    @Binding var isPresentingOverview: Bool

    /// Optimistic local overrides for the watched / favorite toggles. While `nil`,
    /// the buttons reflect Jellyfin's fetched `userData`; a tap sets the override
    /// immediately and is cleared/reverted based on the server response.
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    /// Watched state shown by the button: the pending optimistic value if any,
    /// otherwise Jellyfin's stored status for this item.
    private var isPlayed: Bool {
        playedOverride ?? item.userData?.played ?? false
    }

    /// Favorite state shown by the button: optimistic value if any, otherwise
    /// Jellyfin's stored status.
    private var isFavorite: Bool {
        favoriteOverride ?? item.userData?.isFavorite ?? false
    }

    /// Up to three genres as a single subdued line ("Crime · Drama · Thriller")
    private var genreLine: String? {
        guard let genres = item.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).joined(separator: " · ")
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
                    if item.overview != nil || item.tagline != nil {
                        overviewSection
                    }
                    MediaMetadataRow(
                        yearText: item.yearSpanText,
                        // Series carry a per-episode runtime; the season count
                        // is the meaningful "how much" figure there.
                        runtime: item.type == .series ? nil : item.formattedRuntime,
                        seasons: item.seasonCountText,
                        communityRating: item.communityRating,
                        criticRating: item.criticRating,
                        certificate: item.officialRating,
                        resolution: item.technicalInfo?.resolution,
                        videoRange: item.technicalInfo?.videoRange,
                        audioFormat: item.technicalInfo?.audioFormat
                    )
                    if let genreLine {
                        Text(genreLine)
                            .font(theme.js(.caption, .emphasized))
                            .foregroundStyle(theme.tertiary)
                            .lineLimit(1)
                    }
                }
                CreditsColumn(
                    directorNames: directors.map(\.name),
                    castNames: topCast.map(\.name)
                )
                .frame(width: 250)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpacingTokens.screenPadding)
        .padding(.bottom, SpacingTokens.md)
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
        Text(item.name)
            .font(theme.jsDisplay)
            .foregroundStyle(theme.primary)
    }

    private var playButton: some View {
        Button {
            playbackItem = playTarget
        } label: {
            HStack(spacing: SpacingTokens.sm) {
                Image(systemName: "play.fill")
                Text(playTitle)
            }
            .font(theme.jsHeadline)
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
                isEnabled: session.client != nil
            ) {
                Task { await togglePlayed() }
            }

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
    }

    /// Truncated overview. The description truncates on
    /// the page and lives in a `.plain` Button that reveals the full text in a
    /// full-screen overlay.
    private var overviewSection: some View {
        Button {
            isPresentingOverview = true
        } label: {
            OverviewLabel(tagline: item.tagline, overview: item.overview)
        }
        .plainFocusButtonStyle(tint: theme.focusFill, cornerRadius: theme.cornerRadiusLarge)
    }

    /// Optimistically flip the watched state, then persist; revert on failure.
    private func togglePlayed() async {
        guard let client = session.client else { return }
        let target = !isPlayed
        withAnimation(theme.animation) { playedOverride = target }
        do {
            if target {
                try await client.markPlayed(itemId: item.id)
            } else {
                try await client.markUnplayed(itemId: item.id)
            }
        } catch {
            withAnimation(theme.animation) { playedOverride = !target }
        }
    }

    /// Optimistically flip the favorite state, then persist; revert on failure.
    private func toggleFavorite() async {
        guard let client = session.client else { return }
        let target = !isFavorite
        withAnimation(theme.animation) { favoriteOverride = target }
        do {
            if target {
                try await client.markFavorite(itemId: item.id)
            } else {
                try await client.unmarkFavorite(itemId: item.id)
            }
        } catch {
            withAnimation(theme.animation) { favoriteOverride = !target }
        }
    }
}

import DesignSystem
import JellyfinKit
import SwiftUI

/// Seasons and episodes for a series detail page: a row of season pills over a
/// single episode shelf whose content swaps with the selection (the Apple TV
/// app pattern — compact, and scales to long series).
///
/// Selection is click-driven, not focus-driven: browsing the pills with the
/// remote shouldn't churn the shelf below. Renders nothing while the series'
/// seasons haven't loaded, so the call site can mount it unconditionally.
struct EpisodesSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session

    let seasons: [MediaItem]
    /// Episodes keyed by season id; a missing entry means that season hasn't
    /// been fetched yet (the shelf shows placeholders' absence gracefully —
    /// the LazyHStack is just empty until the fetch lands).
    let episodesBySeason: [String: [MediaItem]]
    @Binding var selectedSeasonId: String?

    var body: some View {
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: SpacingTokens.headerSpacing) {
                HStack(spacing: SpacingTokens.xs) {
                    Image(systemName: "play.tv.fill")
                        .foregroundStyle(theme.accent)
                    Text("Episodes")
                        .font(theme.jsHeadline)
                        .foregroundStyle(theme.primary)
                }
                .padding(.horizontal, SpacingTokens.screenPadding)

                seasonPicker

                episodeShelf
            }
        }
    }

    /// Horizontal row of season pills. The selected pill carries the accent;
    /// pills only re-fetch on click.
    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: SpacingTokens.sm) {
                ForEach(seasons) { season in
                    seasonPill(season)
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.focusPadding)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }

    private func seasonPill(_ season: MediaItem) -> some View {
        Button {
            selectedSeasonId = season.id
        } label: {
            Text(season.name)
                .font(theme.jsBody)
                .fontWeight(.semibold)
                .foregroundStyle(season.id == selectedSeasonId ? theme.accent : theme.primary)
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
    }

    private var episodeShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: SpacingTokens.cardGap) {
                if let selectedSeasonId {
                    ForEach(episodesBySeason[selectedSeasonId] ?? []) { episode in
                        episode.episodeShelfItem(client: session.client)
                    }
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.focusPadding)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }
}

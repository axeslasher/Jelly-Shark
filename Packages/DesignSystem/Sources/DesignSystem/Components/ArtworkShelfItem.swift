import SwiftUI

/// A focusable artwork card for use inside a ``ContentShelf`` or grid.
///
/// Produces the standard tvOS "lockup": the artwork and its two caption lines are
/// **direct children** of the `NavigationLink` label (never wrapped together in a
/// stack), which is what lets `.borderless` move the caption out of the way as the
/// artwork lifts on focus.
///
/// The `.highlight` hover effect is attached explicitly to the whole artwork. The
/// borderless style otherwise lifts the *first `Image` it finds* in the label, and
/// since the real image is an `AsyncImage` nested below `ArtworkImage`'s clip, the
/// default behavior scales that inner image inside the fixed, clipped frame — the
/// "image grows inside its container" bug. Attaching the effect to the card makes
/// the whole artwork lift instead.
///
/// Navigation is value-based: the card appends `value` to the enclosing
/// `NavigationStack`'s path, and the stack's `navigationDestination(for:)`
/// resolves the screen. This keeps the component free of feature/model
/// dependencies and — unlike a view-destination link — lets the app pop the
/// stack programmatically (used to work around a tvOS `sidebarAdaptable` bug
/// where switching tabs with a pushed view strands the pushed screen).
/// Playback-state treatment rendered over the bottom quarter of a card's
/// artwork (episode cards).
public enum PlaybackBadge: Equatable {
    /// Play icon + runtime
    case unplayed(runtime: String?)
    /// Replay icon + runtime
    case played(runtime: String?)
    /// Play icon + progress bar + remaining runtime
    case inProgress(Double, remaining: String?)
}

public struct ArtworkShelfItem<Value: Hashable>: View {
    private let url: URL?
    private let blurHash: String?
    private let title: String
    private let subtitle: String?
    private let synopsis: String?
    private let captionAlignment: HorizontalAlignment
    private let subtitleAboveTitle: Bool
    private let placeholderIcon: String
    private let aspectRatio: CGFloat
    private let width: CGFloat
    private let progress: Double?
    private let playbackBadge: PlaybackBadge?
    private let value: Value?
    private let action: (() -> Void)?

    @Environment(\.theme) private var theme

    public init(
        url: URL?,
        blurHash: String? = nil,
        title: String,
        subtitle: String? = nil,
        synopsis: String? = nil,
        captionAlignment: HorizontalAlignment = .center,
        subtitleAboveTitle: Bool = false,
        placeholderIcon: String = "film.fill",
        aspectRatio: CGFloat = 2.0 / 3.0,
        width: CGFloat = 200,
        progress: Double? = nil,
        playbackBadge: PlaybackBadge? = nil,
        value: Value,
    ) {
        self.action = nil
        self.url = url
        self.blurHash = blurHash
        self.title = title
        self.subtitle = subtitle
        self.synopsis = synopsis
        self.captionAlignment = captionAlignment
        self.subtitleAboveTitle = subtitleAboveTitle
        self.placeholderIcon = placeholderIcon
        self.aspectRatio = aspectRatio
        self.width = width
        self.progress = progress
        self.playbackBadge = playbackBadge
        self.value = value
    }

    /// Action variant: the card runs a closure instead of pushing a
    /// navigation value (episode cards play immediately). `Value` is
    /// meaningless here; the `Bool` constraint just pins the generic.
    public init(
        url: URL?,
        blurHash: String? = nil,
        title: String,
        subtitle: String? = nil,
        synopsis: String? = nil,
        captionAlignment: HorizontalAlignment = .center,
        subtitleAboveTitle: Bool = false,
        placeholderIcon: String = "film.fill",
        aspectRatio: CGFloat = 2.0 / 3.0,
        width: CGFloat = 200,
        progress: Double? = nil,
        playbackBadge: PlaybackBadge? = nil,
        action: @escaping () -> Void,
    ) where Value == Bool {
        self.url = url
        self.blurHash = blurHash
        self.title = title
        self.subtitle = subtitle
        self.synopsis = synopsis
        self.captionAlignment = captionAlignment
        self.subtitleAboveTitle = subtitleAboveTitle
        self.placeholderIcon = placeholderIcon
        self.aspectRatio = aspectRatio
        self.width = width
        self.progress = progress
        self.playbackBadge = playbackBadge
        self.value = nil
        self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cardLabel
                }
            } else if let value {
                NavigationLink(value: value) {
                    cardLabel
                }
            }
        }
        #if os(tvOS)
        .buttonStyle(.borderless)
        #else
        .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private var cardLabel: some View {
        #if os(tvOS)
            // Artwork and captions are intentionally flat siblings, not nested in
            // a stack — the borderless style arranges them into a vertical lockup
            // and moves the captions out of the way as the artwork lifts.
            artwork
            captions
            synopsisText
        #else
            // Other platforms don't apply the borderless lockup, so multiple
            // direct label children lay out horizontally. Stack them explicitly
            // to keep the captions below the artwork.
            VStack(alignment: captionAlignment, spacing: SpacingTokens.xs) {
                artwork
                captions
                synopsisText
            }
        #endif
    }

    private var artwork: some View {
        ArtworkImage(url: url, blurHash: blurHash, placeholderIcon: placeholderIcon)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(width: width)
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: width * progress, height: 4)
                }
            }
            // Playback-state treatment across the bottom quarter of the
            // still: play/replay + runtime, or play + progress bar. A soft
            // scrim keeps it legible over arbitrary artwork.
            .overlay(alignment: .bottom) {
                if let playbackBadge {
                    playbackBadgeContent(playbackBadge)
                        .frame(height: width / aspectRatio / 4)
                        .frame(maxWidth: .infinity)
                        .background {
                            LinearGradient(
                                colors: [theme.background.opacity(0.55), .clear],
                                startPoint: .bottom,
                                endPoint: .top,
                            )
                        }
                }
            }
            .artworkCornerRadius(theme.cornerRadius)
            // Lift, specular highlight, and gimbal motion on focus.
            .hoverEffect(.highlight)
    }

    private func playbackBadgeContent(_ badge: PlaybackBadge) -> some View {
        HStack(spacing: SpacingTokens.xs) {
            switch badge {
            case let .unplayed(runtime):
                Image(systemName: "play.fill")
                if let runtime {
                    Text(runtime)
                }
            case let .played(runtime):
                Image(systemName: "arrow.counterclockwise")
                if let runtime {
                    Text(runtime)
                }
            case let .inProgress(progress, remaining):
                Image(systemName: "play.fill")
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.background.opacity(0.9))
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: geometry.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 8)
                if let remaining {
                    Text(remaining)
                }
            }
        }
        .jsStyle(.body, .subtle)
        .foregroundStyle(theme.primary.opacity(0.9))
        .padding(.horizontal, SpacingTokens.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Multi-line description beneath the captions (episode synopses).
    /// Space is reserved for the full line count whenever a synopsis is
    /// supplied — even an empty one — so cards stay aligned across a row.
    /// Omitted entirely (no reservation) for shelves that never pass one.
    @ViewBuilder
    private var synopsisText: some View {
        if let synopsis {
            Text(synopsis)
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
                .lineLimit(6, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
        }
    }

    /// Title over subtitle by default; flipped, the subtitle reads as a small
    /// eyebrow above the title (episode cards: "S2E4" over the episode name).
    @ViewBuilder
    private var captions: some View {
        if subtitleAboveTitle {
            subtitleText
            titleText
        } else {
            titleText
            subtitleText
        }
    }

    private var titleText: some View {
        Text(title)
            .jsStyle(.title)
            .foregroundStyle(theme.primary)
            .lineLimit(1)
            .frame(width: width, alignment: Alignment(horizontal: captionAlignment, vertical: .center))
    }

    private var subtitleText: some View {
        // Reserve the second line even when empty so cards with one vs. two
        // caption lines stay aligned across a row.
        Text(subtitle ?? " ")
            .jsStyle(.body, .emphasized)
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: Alignment(horizontal: captionAlignment, vertical: .center))
            .opacity(subtitle == nil ? 0 : 1)
    }
}

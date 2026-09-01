import DesignSystem
import JellyfinKit
import SwiftUI

/// Every server library as one grid of cards — the visionOS Libraries tab's
/// content (#138).
///
/// visionOS draws its tabs in an ornament that silently drops any past its
/// limit, with no More affordance and no indication anything is missing. One
/// tab per library therefore let server content push the app's own
/// destinations out of reach: enough libraries and Settings, declared last,
/// simply vanished. Collapsing them behind a single destination makes the
/// ornament a fixed four entries at any library count, and puts the overflow
/// somewhere that can actually overflow — a scroll view.
///
/// A pure renderer: the library list is passed in rather than read from
/// `ServerConnectionViewModel`, so previews can show a populated grid and the
/// view has one reason to re-render. Each card loads its own backdrop lazily
/// (`LibraryCardView`).
///
/// Not platform-guarded, though only visionOS builds reach it. Keeping it
/// plain SwiftUI means the tvOS build and the tvOS-simulator test bundle both
/// type-check it, and the previews below render in the canvas — while the one
/// `#if` that decides who gets this screen stays in `RootView`, where the
/// issue asks for all platform branching to live.
struct LibrariesGridView: View {
    @Environment(\.theme) private var theme

    let libraries: [Library]

    /// Card width, chosen so a default visionOS window fits three across and a
    /// widened one steps up to four. Fixed rather than measured: the library
    /// list is already in hand when this view first renders, so a
    /// geometry-driven width would paint one wrong-sized column on the first
    /// frame with no incoming content to hide it. Adaptive columns compute
    /// inside the layout pass instead, which is right immediately and reflows
    /// on its own when the viewer resizes the window.
    private static let cardWidth: CGFloat = 380

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpacingTokens.md) {
                Text("Libraries")
                    .jsStyle(.headline)
                    .foregroundStyle(theme.primary)

                LazyVGrid(
                    columns: [
                        GridItem(
                            // Pinned min and max: `GenreShelfItem` derives its
                            // 16:9 height from an explicit width, so a
                            // stretched column would leave cards floating in
                            // it rather than filling it.
                            .adaptive(minimum: Self.cardWidth, maximum: Self.cardWidth),
                            spacing: SpacingTokens.cardGap,
                        ),
                    ],
                    alignment: .leading,
                    spacing: SpacingTokens.cardGap,
                ) {
                    ForEach(libraries) { library in
                        LibraryCardView(library: library, width: Self.cardWidth)
                    }
                }
            }
            .padding(.horizontal, SpacingTokens.screenPadding)
            .padding(.vertical, SpacingTokens.lg)
        }
        .scrollClipDisabled()
        .background(theme.background)
    }
}

#if DEBUG
    /// The preview trait's session has no client, so every card renders the
    /// themed wash rather than a sampled backdrop — which is exactly the state
    /// a library with no artwork reaches in production, and the one worth
    /// checking across five themes. The sampled-backdrop state needs a real
    /// server, so it is a device check, not a canvas one.
    private struct LibrariesGridViewPreview: View {
        var body: some View {
            NavigationStack {
                LibrariesGridView(libraries: [
                    Library(id: "preview-movies", name: "Movies", collectionType: .movies),
                    Library(id: "preview-shows", name: "TV Shows", collectionType: .tvshows),
                    Library(id: "preview-docs", name: "Documentaries", collectionType: .movies),
                    Library(id: "preview-kids", name: "Kids & Family", collectionType: .movies),
                    Library(id: "preview-collections", name: "Collections", collectionType: .boxsets),
                ])
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        LibrariesGridViewPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        LibrariesGridViewPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        LibrariesGridViewPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        LibrariesGridViewPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        LibrariesGridViewPreview()
    }
#endif

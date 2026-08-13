import DesignSystem
import JellyfinKit
import SwiftUI

/// A single genre card showing the backdrop that stands in for its genre.
///
/// The choice is remembered across teardown and relaunch by
/// `GenreCardViewModel`, so a card scrolling back into view — or a whole Home
/// screen returning from a detail page — costs no request. Long-pressing rolls
/// a new one. Tapping navigates to the library grid pre-filtered to the genre
/// via a `GenreFilter` value.
///
/// A nil `library` is an unscoped card: it samples, remembers, and links out
/// across every library rather than one. Its remembered face is a separate
/// entry from a scoped card's for the same genre, so the same genre can wear
/// different faces on Home and on a detail page — deliberate, since each card
/// borrows from the pool it actually opens.
struct GenreCardView: View {
    @Environment(AppSession.self) private var session

    let library: Library?
    let genre: String

    @State private var viewModel = GenreCardViewModel()

    var body: some View {
        GenreShelfItem(
            title: genre,
            backdropURL: viewModel.backdropURL(client: session.client),
            blurHash: viewModel.blurHash,
            value: GenreFilter(library: library, genre: genre),
            onBackdropUnavailable: {
                Task { await viewModel.backdropUnavailable(client: session.client, library: library, genre: genre) }
            },
        )
        // Undecorated on purpose: the remembered backdrop is the intended
        // presentation and cycling is a bonus, so this stays a power-user
        // gesture with no badge or nudge — same as `ArtworkShelfItem`'s menu.
        .contextMenu {
            Button("Shuffle image", systemImage: "photo.on.rectangle.angled") {
                Task { await viewModel.cycle(client: session.client, library: library, genre: genre) }
            }
        }
        .task {
            // The store lives on the session, so the handover happens here
            // rather than at init — `@State` cannot read the environment when
            // it builds the view model.
            viewModel.attach(store: session.genreBackdrops)
            await viewModel.load(client: session.client, library: library, genre: genre)
        }
    }
}

#if DEBUG
    /// With no client the sample fetch no-ops and each card renders its seeded
    /// gradient wash — the same face a cold cache shows.
    private struct GenreCardViewPreview: View {
        var body: some View {
            NavigationStack {
                HStack(spacing: SpacingTokens.cardGap) {
                    GenreCardView(library: nil, genre: "Horror")
                    GenreCardView(library: nil, genre: "Comedy")
                    GenreCardView(library: nil, genre: "Documentary")
                }
                .padding(SpacingTokens.screenPadding)
            }
        }
    }

    #Preview("Standard", traits: .featuresEnvironment) {
        GenreCardViewPreview()
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        GenreCardViewPreview()
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        GenreCardViewPreview()
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        GenreCardViewPreview()
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        GenreCardViewPreview()
    }
#endif

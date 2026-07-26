// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
struct GenreCardView: View {
    @Environment(AppSession.self) private var session

    let library: Library
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
            await viewModel.load(client: session.client, library: library, genre: genre)
        }
    }
}

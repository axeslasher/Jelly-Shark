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

import SwiftUI

/// A themed view for remote artwork (posters, backdrops, thumbnails)
///
/// Renders the image over a surface-colored base. While loading (and on
/// failure) it shows the item's decoded blurhash when one is provided — a
/// color-accurate preview of the incoming artwork — otherwise a centered SF
/// Symbol. The surface base is greedy, so the artwork is always cropped to the
/// size the caller proposes even when a fallback image has a different aspect
/// ratio than its slot. The component never drives layout: callers size it
/// with `.frame` or `.aspectRatio` and round it with the `cornerRadius`
/// parameter (or `.clipShape`).
public struct ArtworkImage: View {
    let url: URL?
    let blurHash: String?
    let placeholderIcon: String
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    /// Called when `url` fetches or decodes to nothing — a 404 for an item
    /// that's gone, say. Nil for every caller whose URL was derived from an
    /// item it was just handed by the server; genre cards pass one because
    /// their URL comes from a *remembered* choice that can go stale (#124).
    let onLoadFailure: (@MainActor () -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// Decoded blurhash placeholder; decoding happens off the main actor in
    /// the view's task and usually beats the network image comfortably.
    @State private var blurPlaceholder: CGImage?

    /// The artwork, from `ArtworkLoader`'s decoded cache (instant on remount)
    /// or fetched + decoded on first sight.
    @State private var artwork: CGImage?

    /// The size the caller proposed, measured so the decode can be capped to
    /// the pixels the slot actually needs. Stays `.zero` if geometry hasn't
    /// committed by load time (e.g. mid-transition), in which case the image
    /// decodes at native size — the pre-loader behavior.
    @State private var slotSize: CGSize = .zero

    public init(
        url: URL?,
        blurHash: String? = nil,
        placeholderIcon: String = "photo",
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 0,
        onLoadFailure: (@MainActor () -> Void)? = nil,
    ) {
        self.url = url
        self.blurHash = blurHash
        self.placeholderIcon = placeholderIcon
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.onLoadFailure = onLoadFailure
    }

    public var body: some View {
        // A greedy surface base takes the exact size the caller proposes, so the
        // image (laid on top and filled) is always cropped to the card's box —
        // even when a fallback image has a different aspect ratio than the slot.
        theme.surface
            .overlay {
                if let artwork {
                    Image(decorative: artwork, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    placeholder
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { slotSize = $0 }
            .artworkCornerRadius(cornerRadius)
            .accessibilityHidden(true)
            .task(id: url) {
                await loadArtwork()
            }
            .task(id: blurHash) {
                guard let blurHash else {
                    blurPlaceholder = nil
                    return
                }
                blurPlaceholder = await decodeBlurHash(blurHash)
            }
    }

    private func loadArtwork() async {
        guard let url else {
            artwork = nil
            return
        }
        // A changed URL drops the stale image so the blurhash/placeholder
        // shows while the replacement loads (cache hits repaint immediately).
        artwork = nil
        if slotSize == .zero {
            // The first layout pass usually hasn't committed when the task
            // starts; one yield lets the measured size land before decode.
            await Task.yield()
        }
        let slotPixelSize: CGSize? = slotSize == .zero
            ? nil
            : CGSize(width: slotSize.width * displayScale, height: slotSize.height * displayScale)
        let image = try? await ArtworkLoader.shared.image(
            at: url,
            slotPixelSize: slotPixelSize,
            contentMode: contentMode,
        )
        // The loader's awaits don't observe cancellation, so a superseded load
        // (URL changed mid-flight) can resume late — don't let it clobber the
        // current image.
        if !Task.isCancelled {
            artwork = image
            // Cancellation isn't failure, which is why this is reported only
            // on the branch that commits the result.
            if image == nil {
                onLoadFailure?()
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let blurPlaceholder {
            Image(decorative: blurPlaceholder, scale: 1)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Image(systemName: placeholderIcon)
                .font(.system(size: 32))
                .foregroundStyle(theme.tertiary)
        }
    }
}

/// Hop off the main actor for the decode — it's pure math, and shelves mount
/// many cards at once.
private func decodeBlurHash(_ hash: String) async -> CGImage? {
    BlurHash.decode(hash)
}

public extension View {
    /// Clips a view to a continuous rounded rectangle. A radius of `0` produces
    /// the same square-cornered clip as `.clipped()`.
    func artworkCornerRadius(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

#Preview {
    HStack(spacing: SpacingTokens.lg) {
        ArtworkImage(url: nil, placeholderIcon: "film.fill")
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))

        ArtworkImage(url: nil)
            .frame(width: 320, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .withThemeEnvironment()
}

import CoreGraphics
import ImageIO
import SwiftUI

/// Loads a logo image and trims its transparent margins before display.
///
/// Logo artwork (fanart, TMDb) ships with wildly inconsistent transparent
/// padding baked into the PNG — a logo aligned `bottomLeading` in a frame can
/// still render floating somewhere inside it because the bitmap's edges are
/// invisible pixels. Cropping to the alpha bounding box makes every logo sit
/// flush against the frame edge it's aligned to.
///
/// API mirrors `AsyncImage`: `content` receives the trimmed `Image`;
/// `fallback` shows while loading and on failure. Fetches go through
/// `URLSession.shared`, so they hit the same `URLCache` as the rest of the
/// artwork.
struct TrimmedLogoImage<Content: View, Fallback: View>: View {
    let url: URL
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let fallback: () -> Fallback

    @State private var trimmed: CGImage?

    var body: some View {
        if let trimmed {
            content(Image(decorative: trimmed, scale: 1))
        } else {
            fallback()
                .task(id: url) {
                    trimmed = await loadTrimmedLogo(from: url)
                }
        }
    }
}

/// Fetch, decode, and alpha-trim off the main actor. Returns nil on any
/// failure — the view just keeps its fallback, matching `AsyncImage`.
/// Free functions rather than members so the hop off the main actor doesn't
/// drag the view's generic `View` conformances into a concurrent context.
private func loadTrimmedLogo(from url: URL) async -> CGImage? {
    guard let (data, _) = try? await URLSession.shared.data(from: url),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return trimmingTransparentMargins(of: image)
}

/// Crop to the bounding box of visibly opaque pixels. Returns the image
/// unchanged when it has no alpha to trim or the scan finds nothing
/// (fully transparent — better to show something than nothing).
private func trimmingTransparentMargins(of image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0,
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
          )
    else { return image }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return image }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    // Ignore near-invisible haloing around the artwork, not just alpha 0.
    let threshold: UInt8 = 16
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0 ..< height {
        let row = y * width * 4
        for x in 0 ..< width where pixels[row + x * 4 + 3] > threshold {
            if x < minX {
                minX = x
            }
            if x > maxX {
                maxX = x
            }
            if y < minY {
                minY = y
            }
            if y > maxY {
                maxY = y
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return image }
    let box = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    guard box.size != CGSize(width: width, height: height) else { return image }

    // CGContext draws with a flipped y-axis relative to CGImage.cropping's
    // coordinate space, so mirror the box vertically.
    let cropRect = CGRect(x: box.minX, y: CGFloat(height) - box.maxY, width: box.width, height: box.height)
    return image.cropping(to: cropRect) ?? image
}

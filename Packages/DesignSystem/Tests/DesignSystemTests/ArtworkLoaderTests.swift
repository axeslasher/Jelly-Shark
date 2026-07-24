import CoreGraphics
@testable import DesignSystem
import Foundation
import ImageIO
import SwiftUI
import Testing

@Suite("ArtworkLoader downsampling")
struct ArtworkLoaderTests {
    @Test("Image already smaller than the slot decodes native (no cap)")
    func smallerImageIsUncapped() {
        let cap = ArtworkLoader.targetMaxPixelSize(
            imagePixelSize: CGSize(width: 400, height: 600),
            slotPixelSize: CGSize(width: 500, height: 750),
            contentMode: .fill,
        )
        #expect(cap == nil)
    }

    @Test("Fill cap covers the slot even when aspects differ")
    func fillCapCoversMismatchedAspect() {
        // 16:9 image filling a 2:3 poster slot: height is the binding axis,
        // so the decode must keep enough width resolution for the crop.
        let cap = ArtworkLoader.targetMaxPixelSize(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            slotPixelSize: CGSize(width: 500, height: 750),
            contentMode: .fill,
        )
        #expect(cap == Int((1920.0 * (750.0 / 1080.0)).rounded(.up)))
    }

    @Test("Fit cap uses the smaller ratio")
    func fitCapUsesSmallerRatio() {
        let cap = ArtworkLoader.targetMaxPixelSize(
            imagePixelSize: CGSize(width: 1920, height: 1080),
            slotPixelSize: CGSize(width: 500, height: 750),
            contentMode: .fit,
        )
        #expect(cap == Int((1920.0 * (500.0 / 1920.0)).rounded(.up)))
    }

    @Test("Degenerate sizes decode native")
    func degenerateSizesAreUncapped() {
        #expect(ArtworkLoader.targetMaxPixelSize(
            imagePixelSize: .zero,
            slotPixelSize: CGSize(width: 500, height: 750),
            contentMode: .fill,
        ) == nil)
        #expect(ArtworkLoader.targetMaxPixelSize(
            imagePixelSize: CGSize(width: 400, height: 600),
            slotPixelSize: .zero,
            contentMode: .fill,
        ) == nil)
    }

    @Test("Decode caps an oversized source to the slot's pixels")
    func decodeDownsamplesToSlot() throws {
        let data = try #require(pngData(width: 400, height: 600))
        let image = try #require(ArtworkLoader.downsampledImage(
            data: data,
            slotPixelSize: CGSize(width: 100, height: 150),
            contentMode: .fill,
        ))
        #expect(max(image.width, image.height) == 150)
    }

    @Test("Decode without a slot keeps the native size")
    func decodeWithoutSlotIsNative() throws {
        let data = try #require(pngData(width: 400, height: 600))
        let image = try #require(ArtworkLoader.downsampledImage(
            data: data,
            slotPixelSize: nil,
            contentMode: .fill,
        ))
        #expect(image.width == 400)
        #expect(image.height == 600)
    }

    /// A solid-color PNG of the given pixel size.
    private func pngData(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

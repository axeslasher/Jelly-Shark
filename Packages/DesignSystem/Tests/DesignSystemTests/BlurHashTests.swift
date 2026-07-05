import CoreGraphics
import Foundation
import Testing
@testable import DesignSystem

@Suite("BlurHash Decoder")
struct BlurHashTests {
    /// The blurha.sh reference example hash.
    private let validHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

    @Test("Decodes a valid hash at the requested size")
    func decodesValidHash() {
        let image = BlurHash.decode(validHash, width: 32, height: 32)
        #expect(image != nil)
        #expect(image?.width == 32)
        #expect(image?.height == 32)
    }

    @Test("Repeated decodes hit the cache and return the same image")
    func cacheReturnsSameInstance() {
        let first = BlurHash.decode(validHash)
        let second = BlurHash.decode(validHash)
        #expect(first != nil)
        #expect(first === second)
    }

    @Test("Rejects malformed input")
    func rejectsMalformedInput() {
        // Too short to carry its header.
        #expect(BlurHash.decode("LEH") == nil)
        // Component count doesn't match the payload length.
        #expect(BlurHash.decode(String(validHash.dropLast())) == nil)
        // Characters outside the base83 alphabet.
        #expect(BlurHash.decode("L\u{00E9}HV6nWB2yk8pyo0adR*.7kCMdnj") == nil)
        #expect(BlurHash.decode("") == nil)
    }

    @Test("Decodes channels in RGB order")
    func decodesChannelOrder() throws {
        // Hand-encoded hash of a solid pure-red image: 1×1 components
        // (sizeFlag "0"), any max ("0"), DC = 0xFF0000 in base83 ("TI:j"),
        // no AC payload. Every pixel should decode red-dominant.
        let image = try #require(BlurHash.decode("00TI:j", width: 8, height: 8))
        let data = try #require(image.dataProvider?.data as Data?)
        let center = 4 * image.bytesPerRow + 4 * 4
        let red = data[center]
        let green = data[center + 1]
        let blue = data[center + 2]
        #expect(red > 250)
        #expect(green < 5)
        #expect(blue < 5)
    }
}

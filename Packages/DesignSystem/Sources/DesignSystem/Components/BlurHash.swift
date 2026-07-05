import CoreGraphics
import Foundation

/// Decoder for the BlurHash compact image placeholder format
/// (https://blurha.sh) — a short base83 string encoding a handful of DCT
/// components, decoded into a tiny gradient-like image shown while the real
/// artwork loads.
public enum BlurHash {
    /// Decode a blurhash into a small `CGImage`. Returns nil for malformed
    /// input. Results are cached by hash+size — placeholders repeat heavily
    /// across shelves, and a decode is pure math worth doing once.
    ///
    /// The default 32×32 canvas is intentionally tiny: a blurhash carries at
    /// most 9×9 frequency components, so decoding larger just burns CPU —
    /// callers stretch the result with `.resizable()`, and the upscale blur is
    /// the aesthetic.
    public static func decode(_ hash: String, width: Int = 32, height: Int = 32, punch: Float = 1) -> CGImage? {
        let key = "\(hash)|\(width)x\(height)|\(punch)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = decodeUncached(hash, width: width, height: height, punch: punch) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// NSCache is thread-safe and CGImage is immutable, so shared mutable
    /// state here is benign.
    private nonisolated(unsafe) static let cache = NSCache<NSString, CGImage>()

    private static func decodeUncached(_ hash: String, width: Int, height: Int, punch: Float) -> CGImage? {
        let chars = Array(hash)
        guard chars.count >= 6, let sizeFlag = decode83(chars[0...0]) else { return nil }

        let componentsX = (sizeFlag % 9) + 1
        let componentsY = (sizeFlag / 9) + 1
        guard chars.count == 4 + 2 * componentsX * componentsY,
              let quantisedMaximum = decode83(chars[1...1])
        else { return nil }

        let maximumValue = Float(quantisedMaximum + 1) / 166 * punch

        var colors: [(Float, Float, Float)] = []
        colors.reserveCapacity(componentsX * componentsY)

        guard let dcValue = decode83(chars[2...5]) else { return nil }
        colors.append((
            sRGBToLinear((dcValue >> 16) & 255),
            sRGBToLinear((dcValue >> 8) & 255),
            sRGBToLinear(dcValue & 255)
        ))

        for component in 1..<(componentsX * componentsY) {
            let start = 4 + component * 2
            guard let acValue = decode83(chars[start...(start + 1)]) else { return nil }
            colors.append((
                signPow((Float(acValue / (19 * 19)) - 9) / 9, 2) * maximumValue,
                signPow((Float((acValue / 19) % 19) - 9) / 9, 2) * maximumValue,
                signPow((Float(acValue % 19) - 9) / 9, 2) * maximumValue
            ))
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<componentsY {
                    let cosY = cos(.pi * Float(y) * Float(j) / Float(height))
                    for i in 0..<componentsX {
                        let basis = cos(.pi * Float(x) * Float(i) / Float(width)) * cosY
                        let color = colors[i + j * componentsX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = linearToSRGB(r)
                pixels[offset + 1] = linearToSRGB(g)
                pixels[offset + 2] = linearToSRGB(b)
            }
        }

        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        return context?.makeImage()
    }

    // MARK: - Encoding primitives

    private static let base83Characters = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    private static func decode83(_ chars: ArraySlice<Character>) -> Int? {
        var value = 0
        for character in chars {
            guard let digit = base83Characters.firstIndex(of: character) else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> UInt8 {
        let v = min(max(value, 0), 1)
        let converted = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(converted * 255 + 0.5)
    }

    private static func signPow(_ value: Float, _ exponent: Float) -> Float {
        copysign(pow(abs(value), exponent), value)
    }
}

// Renders each Image(systemName:) at 18pt through SwiftUI's ImageRenderer and prints, per symbol,
// the layout box SwiftUI gives it and where the ink sits inside that box (points, top-left
// origin). Also writes the render's 8-bit alpha so pipeline.py can read each layer's opacity.
// Built for a tvOS simulator and run with `simctl spawn` by run.sh — tvOS and visionOS renders
// were byte-identical for all 70 symbols, so one platform stands for both.
//
// Usage: probe <alpha output dir> <symbol>...
import SwiftUI

let alphaDir = CommandLine.arguments[1]
let names = CommandLine.arguments.dropFirst(2)
let scale: CGFloat = 8

@MainActor func probe() {
    for name in names {
        let renderer = ImageRenderer(content: Image(systemName: name)
            .font(.system(size: 18, weight: .regular))
            .imageScale(.medium)
            .foregroundStyle(.black))
        renderer.scale = scale
        guard let cg = renderer.cgImage else {
            print("\(name)\tERROR")
            continue
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            print("\(name)\tERROR")
            continue
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Bitmap memory starts at the top row, so the row index is already a top-left-origin y.
        var alpha = [UInt8](repeating: 0, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0 ..< h {
            for x in 0 ..< w {
                let a = px[(y * w + x) * 4 + 3]
                alpha[y * w + x] = a
                if a > 127 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        FileManager.default.createFile(atPath: "\(alphaDir)/\(name).a8", contents: Data(alpha))
        let pt = { (v: Int) in String(format: "%.3f", Double(v) / Double(scale)) }
        print([name, pt(w), pt(h), pt(minX), pt(minY), pt(maxX + 1), pt(maxY + 1)].joined(separator: "\t"))
    }
}

MainActor.assumeIsolated { probe() }

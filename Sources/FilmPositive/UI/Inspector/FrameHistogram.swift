import Foundation
import CoreGraphics

/// An RGB histogram of the frame the inspector is showing.
///
/// It reads the SAME 16-bit buffer the exporter writes. `RenderCoordinator` caches
/// `Exporter.cgImage(result.frame, tagged:)`, which wraps `DecodedFrame.pixels` in a
/// `CGDataProvider` with `bitsPerComponent: 16` and no conversion, so the bytes behind the
/// cached `CGImage` are the render's 16-bit samples themselves. That is why this type asks
/// for a `CGImage` rather than a `DecodedFrame`: there is no second path and no 8-bit
/// intermediate to drift from.
///
/// If the image is ever not 16 bits per component, this returns nil rather than a
/// plausible-looking 8-bit histogram. A wrong histogram that renders is worse than an
/// absent one, because nothing downstream could tell the difference.
struct FrameHistogram: Equatable, Sendable {
    static let binCount = 256

    let red: [Int]
    let green: [Int]
    let blue: [Int]
    /// The largest count in any bin of any channel, which normalizes the drawing.
    let peak: Int
    /// How many pixels were actually counted (the buffer is strided for large frames).
    let sampleCount: Int
    /// Recorded so a regression to 8-bit is visible rather than silent.
    let bitsPerComponent: Int

    /// Above this many pixels the buffer is strided. A proxy of a 20 MP frame is about
    /// 5 M pixels, and a histogram drawn 300 points wide cannot show the difference.
    static let sampleBudget = 400_000

    var isEmpty: Bool { sampleCount == 0 }

    /// The one-line caption under the histogram. Deliberately says "sampled": the buffer is
    /// strided above `sampleBudget`, so this is the count the histogram read and not the
    /// frame's own resolution, and rounding it into a megapixel figure would quietly report
    /// a different quantity from the one the reader assumes.
    var shortCaption: String {
        let bits = "\(bitsPerComponent)-bit"
        if sampleCount >= 1_000_000 {
            // Interpolated rather than String(format:) with %@: that specifier wants an
            // object, and handing it a Swift String is the same class of Foundation fault
            // `HistogramView` avoids for its accessibility value.
            return "\(String(format: "%.1f", Double(sampleCount) / 1_000_000)) MP sampled · \(bits)"
        }
        return "\(sampleCount / 1000)k px sampled · \(bits)"
    }

    func channel(_ index: Int) -> [Int] {
        switch index {
        case 0: return red
        case 1: return green
        default: return blue
        }
    }

    /// Counts a 16-bit RGB `CGImage`. Nil when the image is not 16 bits per component,
    /// when it carries fewer than three components, or when its bytes are unreadable.
    init?(image: CGImage) {
        guard image.bitsPerComponent == 16 else { return nil }
        // Derived from the image's own depth, not from a hardcoded 16, so the count is right
        // at any depth: an 8-bit RGBA image is 32 bits per pixel, and 32 / 16 would count 2.
        let componentsPerPixel = image.bitsPerPixel / image.bitsPerComponent
        guard componentsPerPixel >= 3 else { return nil }
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerComponent = image.bitsPerComponent / 8
        guard width > 0, height > 0, bytesPerRow >= width * componentsPerPixel * bytesPerComponent else { return nil }
        guard CFDataGetLength(data) >= bytesPerRow * height else { return nil }

        // Stride whole pixels, never bytes, so a sample is always a real RGB triple.
        let total = width * height
        let stride = max(1, Int((Double(total) / Double(Self.sampleBudget)).rounded(.up)))

        var r = [Int](repeating: 0, count: Self.binCount)
        var g = [Int](repeating: 0, count: Self.binCount)
        var b = [Int](repeating: 0, count: Self.binCount)
        var counted = 0
        // 65536 sample values into 256 bins: an exact right shift, no rounding bias.
        let shift = 8

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            row.withMemoryRebound(to: UInt16.self, capacity: width * componentsPerPixel) { px in
                var x = (y * width) % stride == 0 ? 0 : stride - ((y * width) % stride)
                while x < width {
                    let i = x * componentsPerPixel
                    r[Int(px[i]) >> shift] += 1
                    g[Int(px[i + 1]) >> shift] += 1
                    b[Int(px[i + 2]) >> shift] += 1
                    counted += 1
                    x += stride
                }
            }
        }

        red = r
        green = g
        blue = b
        sampleCount = counted
        peak = max(r.max() ?? 0, max(g.max() ?? 0, b.max() ?? 0))
        bitsPerComponent = image.bitsPerComponent
    }

    /// Direct construction from 16-bit interleaved RGB, used by the tests and available
    /// if the coordinator is ever changed to hand out the `DecodedFrame` itself.
    init(pixels: [UInt16], width: Int, height: Int) {
        var r = [Int](repeating: 0, count: Self.binCount)
        var g = [Int](repeating: 0, count: Self.binCount)
        var b = [Int](repeating: 0, count: Self.binCount)
        let total = min(width * height, pixels.count / 3)
        let stride = max(1, Int((Double(total) / Double(Self.sampleBudget)).rounded(.up)))
        var counted = 0
        var p = 0
        while p < total {
            let i = p * 3
            r[Int(pixels[i]) >> 8] += 1
            g[Int(pixels[i + 1]) >> 8] += 1
            b[Int(pixels[i + 2]) >> 8] += 1
            counted += 1
            p += stride
        }
        red = r
        green = g
        blue = b
        sampleCount = counted
        peak = max(r.max() ?? 0, max(g.max() ?? 0, b.max() ?? 0))
        bitsPerComponent = 16
    }
}

import Foundation

/// The base estimated from the picture, for a frame whose film edge cannot be read.
///
/// A per-channel percentile white point, the classic auto-levels estimate that scanner
/// software has used for decades: the brightest tail of each channel of the negative stands
/// in for the film base.
///
/// Why it works well enough to be a rung: the thinnest part of a negative is the base plus
/// a little fog, so the brightest few pixels of each channel sit near the base in both
/// level and color. On a ten-frame crop ladder the 99.9th percentile of a
/// frame cropped past its rebate landed within 15 percent of that frame's own edge reading
/// in both ratios on 18 of 20 crops. It is an estimate and the status line says so ("Base:
/// estimated from the picture"): a frame with no thin area at all (a dark night shot has
/// no shadows on the negative) has no tail near the base.
extension Calibrator {
    /// The percentile of each channel taken as the base.
    public static let pictureBasePercentile = 0.999

    /// Per-channel `pictureBasePercentile` over `box` of the frame (the whole frame when
    /// nil), or nil when no estimate is possible: too few pixels, a channel at zero, or a
    /// channel whose tail is at the clip guard, which means lamp is in view and the tail is
    /// the lamp rather than the film.
    ///
    /// Every pixel in the box is read. The percentile is the smallest value whose
    /// cumulative count reaches `ceil(p * n)`, per channel, from a full 16-bit histogram,
    /// so it is exact and costs one pass.
    public static func pictureEstimate(_ f: DecodedFrame, box: DevelopMath.CropBox? = nil) -> [Double]? {
        let b = box ?? DevelopMath.CropBox(x0: 0, y0: 0, x1: f.width, y1: f.height)
        let x0 = max(0, b.x0), y0 = max(0, b.y0), x1 = min(f.width, b.x1), y1 = min(f.height, b.y1)
        guard x1 > x0, y1 > y0 else { return nil }
        let n = (x1 - x0) * (y1 - y0)
        guard n > minRebatePixels else { return nil }
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 65536), count: 3)
        f.pixels.withUnsafeBufferPointer { p in
            for y in y0..<y1 {
                var i = (y * f.width + x0) * 3
                for _ in x0..<x1 {
                    hist[0][Int(p[i])] += 1
                    hist[1][Int(p[i + 1])] += 1
                    hist[2][Int(p[i + 2])] += 1
                    i += 3
                }
            }
        }
        let target = Int((pictureBasePercentile * Double(n)).rounded(.up))
        var base = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            var acc = 0
            var v = 0
            while v < 65536 {
                acc += hist[c][v]
                if acc >= target { break }
                v += 1
            }
            base[c] = Double(min(v, 65535))
        }
        guard base.allSatisfy({ $0 > 0 && $0 < Double(clipGuard) }) else { return nil }
        return base
    }
}

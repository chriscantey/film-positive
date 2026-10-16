import Foundation
import CoreImage
import FilmSidecar

// Levels and Curves, the two tone stages that sit in `CoreImageEnhance.chain` after
// Brightness and before Warmth and Tint: tone before color, as the rest of the chain is
// ordered.
//
// THE ENCODING. Both act on DISPLAY-ENCODED values, the scale the histogram shows, because a
// handle placed under a histogram bin has to move that bin. The chain does not hold that scale
// at this point. Its context is managed with the default working space, which is extended
// LINEAR sRGB (probed: `workingColorSpace` reads
// kCGColorSpaceExtendedLinearSRGB, and a color matrix of 0.5 applied there turned an encoded
// 0.5 into 0.3608, not 0.25). So each stage converts in and out:
//
// - Levels with `CILinearToSRGBToneCurve` before and `CISRGBToneCurveToLinear` after, and
//   its formula as four plain filters between them, so it is exact rather than sampled.
// - Curves through `CIColorCurves` with `inputColorSpace` sRGB, which makes the filter do the
//   same conversion itself (probed: a table of y = x / 2 turned encoded 0.5 into 0.2499 with
//   sRGB named, and into linear-light halving with the default space).

/// Which of the two tone stages a histogram describes the input of. (`ToneStep` is taken: it
/// is develop's tone operator.)
public enum EnhanceToneStage: Sendable, Equatable {
    case levels, curves
}

/// The Levels formula and its guard, free of Core Image so it can be asserted at known values.
public enum LevelsMath {
    /// Midtone gamma is held to this range in the render, whatever the file says.
    public static let gammaRange: ClosedRange<Double> = 0.1...10
    /// Input white is kept at least this far above input black.
    public static let minimumInputSpan = 0.01

    /// The values the render actually uses. The reader accepts any five finite numbers, so the
    /// render guards here: gamma into `gammaRange`, input white at least `minimumInputSpan`
    /// above input black (white moves, black stays). A non-finite value, which no reader
    /// produces but a hand-built struct could, falls back to that field's identity.
    public static func guarded(_ l: Levels) -> Levels {
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        let inBlack = finite(l.inBlack, 0)
        let gamma = min(max(finite(l.gamma, 1), gammaRange.lowerBound), gammaRange.upperBound)
        let inWhite = max(finite(l.inWhite, 1), inBlack + minimumInputSpan)
        return Levels(inBlack: inBlack, gamma: gamma, inWhite: inWhite,
                      outBlack: finite(l.outBlack, 0), outWhite: finite(l.outWhite, 1))
    }

    /// `out = outBlack + (outWhite - outBlack) * pow(clamp((v - inBlack) / (inWhite - inBlack), 0, 1), 1 / gamma)`,
    /// on a display-encoded value, after `guarded`.
    public static func apply(_ raw: Levels, to v: Double) -> Double {
        let l = guarded(raw)
        let t = min(max((v - l.inBlack) / (l.inWhite - l.inBlack), 0), 1)
        return l.outBlack + (l.outWhite - l.outBlack) * pow(t, 1 / l.gamma)
    }
}

/// One tone curve as a monotone cubic through its points (Fritsch and Carlson, 1980): a
/// Hermite cubic per interval with the tangents limited so that between two points the curve
/// never leaves the band those two points span. A run of rising points stays rising, a flat
/// pair stays flat, and nothing overshoots the way a natural spline does next to a sharp
/// bend. Left of the first point the curve holds the first point's y, right of the last the
/// last point's, and the result is clamped to 0...1.
public struct MonotoneCurve: Sendable, Equatable {
    public let xs: [Double]
    public let ys: [Double]
    /// The tangent at each point.
    public let slopes: [Double]
    /// Exactly the identity points, so evaluation can return its input bit for bit.
    public let isIdentity: Bool

    public init(_ curve: CurvePoints) {
        // Through the sanitiser, so a hand-built list (unsorted, repeated x, one point) still
        // yields a curve. Every curve the reader hands back is already in this form.
        let points = CurvePoints(sanitising: curve.points).points
        xs = points.map(\.x)
        ys = points.map(\.y)
        isIdentity = CurvePoints(points: points).isIdentity
        let n = points.count
        var secant = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) { secant[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = secant[0]
        m[n - 1] = secant[n - 2]
        if n > 2 {
            // An interior point where the curve turns round gets a flat tangent, which is what
            // keeps a peak or a valley at the point the person put there.
            for k in 1..<(n - 1) {
                m[k] = secant[k - 1] * secant[k] > 0 ? (secant[k - 1] + secant[k]) / 2 : 0
            }
        }
        for k in 0..<(n - 1) {
            if secant[k] == 0 { m[k] = 0; m[k + 1] = 0; continue }
            let a = m[k] / secant[k], b = m[k + 1] / secant[k]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[k] = t * a * secant[k]
                m[k + 1] = t * b * secant[k]
            }
        }
        slopes = m
    }

    public func value(at x: Double) -> Double {
        if isIdentity { return min(max(x, 0), 1) }
        guard x > xs[0] else { return ys[0] }
        guard x < xs[xs.count - 1] else { return ys[ys.count - 1] }
        // The interval holding x: the last k with xs[k] <= x.
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let h = xs[lo + 1] - xs[lo], t = (x - xs[lo]) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * ys[lo] + (t3 - 2 * t2 + t) * h * slopes[lo]
            + (-2 * t3 + 3 * t2) * ys[lo + 1] + (t3 - t2) * h * slopes[lo + 1]
        return min(max(y, 0), 1)
    }
}

/// The four curves sampled into the one table `CIColorCurves` takes.
public enum CurveTable {
    /// Entries per channel. 4096 keeps the linear interpolation the filter does between
    /// entries far under one 16-bit step for any curve the editor can draw, and the table is
    /// 48 KB, rebuilt on every drag tick in well under a millisecond.
    public static let size = 4096

    /// Red, green, blue interleaved, `size` entries each: `rgb` first, then each channel's own
    /// curve on the result, so entry i of red is `red(rgb(i / (size - 1)))`.
    public static func table(_ c: Curves) -> [Float] {
        let all = MonotoneCurve(c.rgb), r = MonotoneCurve(c.red), g = MonotoneCurve(c.green), b = MonotoneCurve(c.blue)
        var out = [Float](repeating: 0, count: size * 3)
        let last = Double(size - 1)
        for i in 0..<size {
            let v = all.value(at: Double(i) / last)
            out[i * 3] = Float(r.value(at: v))
            out[i * 3 + 1] = Float(g.value(at: v))
            out[i * 3 + 2] = Float(b.value(at: v))
        }
        return out
    }
}

extension CoreImageEnhance {
    /// Levels as five exact filters in display encoding. Values that come in above 1 (an
    /// Exposure push in linear light can make them) are clamped by the formula like any other
    /// value past input white.
    static func levels(_ ci: CIImage, _ raw: Levels) -> CIImage {
        let l = LevelsMath.guarded(raw)
        let k = CGFloat(1 / (l.inWhite - l.inBlack)), bias = CGFloat(-l.inBlack) * k
        let span = CGFloat(l.outWhite - l.outBlack), floor = CGFloat(l.outBlack)
        return ci.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": CGFloat(1 / l.gamma)])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: span, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: span, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: span, w: 0),
                "inputBiasVector": CIVector(x: floor, y: floor, z: floor, w: 0),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Curves as one `CIColorCurves` step over a `CurveTable`. The filter clamps its input to
    /// the table's domain, so a value above 1 (encoded) takes the curve's value at 1, the
    /// table's last entry, and a value below 0 its value at 0 (probed: an identity table
    /// returned an encoded 2.0 as 1.0).
    static func curves(_ ci: CIImage, _ c: Curves) -> CIImage {
        let data = CurveTable.table(c).withUnsafeBufferPointer { Data(buffer: $0) }
        return ci.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": srgb,
        ])
    }

    /// The settings whose render is the picture AS IT ENTERS `step`: every stage before it as
    /// set, every stage from it on at identity. The chain runs Exposure, Radiance, Shadows and
    /// Highlights, Black Point, Contrast, Brightness, then Levels, then Curves, so this keeps
    /// exactly those. `EnteringStepTests` renders it against `chain(stoppingBefore:)`, which
    /// is what keeps this list and the chain's order from drifting apart.
    public static func entering(_ step: EnhanceToneStage, _ s: EnhanceSettings) -> EnhanceSettings {
        var out = EnhanceSettings()
        out.exposure = s.exposure
        out.radiance = s.radiance
        out.shadows = s.shadows
        out.highlights = s.highlights
        out.blackPoint = s.blackPoint
        out.contrast = s.contrast
        out.brightness = s.brightness
        if step == .curves { out.levels = s.levels }
        return out
    }
}

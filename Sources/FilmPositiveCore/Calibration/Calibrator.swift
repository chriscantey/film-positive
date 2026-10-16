import Foundation
import CoreGraphics
import FilmSidecar

/// The film base measurement, ported from the TypeScript engine's `src/calibrate.ts`: the
/// rebate estimate the develop pass reads the base from, the eyedropper's patch estimate,
/// and the roll-level base measurement.
///
/// The roll-level measurement (`measureBase`) serves profile fitting outside the app only.
/// Nothing in the app fits a stock.
///
/// Every rule here is the TS rule. It is graded on synthetic rolls whose base pair the
/// test chooses, so what is asserted is that the measurement recovers numbers that are
/// known by construction (`CalibratorTests`). Where a JavaScript idiom and a Swift one
/// differ, the comment says which JavaScript behavior is being reproduced, because those
/// are the places a port silently drifts:
///
///   - `median` takes the UPPER middle of an even-length list, because JavaScript's
///     `sorted[Math.floor(n / 2)]` does, and on six frames that choice moves the base.
///   - histogram bins are integer arithmetic on the raw 16-bit value, `v >> 7`.
///   - `Math.round` on a positive value is round-half-up, matched with
///     `.rounded(.toNearestOrAwayFromZero)` over the same positive domain.
///   - `toFixed(n)` rounds the EXACT binary value of the double, so it is reproduced by
///     formatting rather than by scaling and rounding, which gets the near halves backwards.
public enum Calibrator {
    // MARK: - constants (the TS values, named the same)

    /// Fraction of the frame height at each edge that is sprocket margin.
    public static let rebateMargin = 0.09
    /// A channel at or above this is at the sensor ceiling and biases the estimate low.
    public static let clipGuard: Int = 65000
    /// A whole per-frame estimate at or above this is bare backlight, not film base.
    public static let ceilingReject = 63500.0
    /// Below this many clean pixels a strip has no usable rebate.
    public static let minRebatePixels = 500
    /// Below this many clean pixels a hand-picked patch has nothing worth averaging.
    /// Far lower than `minRebatePixels` and deliberately so: a strip is the whole width of
    /// the frame and a patch is a square the user aimed, so the two are not the same kind
    /// of sample. At the default radius on a proxy decode the patch holds tens of
    /// thousands of pixels, and this guard is only about the degenerate cases: a click at
    /// the very corner, or a patch that is entirely at the sensor ceiling.
    public static let minPatchPixels = 100
    public static let qualityGoodMax = 2.0
    public static let qualityFairMax = 6.0

    // MARK: - shapes

    public struct Quality: Codable, Equatable, Sendable {
        public enum Verdict: String, Codable, Sendable { case good, fair, poor }
        public var framesUsed: Int
        public var spreadPct: Double
        public var verdict: Verdict
        public init(framesUsed: Int, spreadPct: Double, verdict: Verdict) {
            self.framesUsed = framesUsed; self.spreadPct = spreadPct; self.verdict = verdict
        }
    }

    public enum Method: String, Codable, Sendable {
        case baseFrames = "base-frames"
        case rebateMedian = "rebate-median"
    }

    /// One frame offered to `measureBase`. `base` is a dedicated blank base frame, `image` is
    /// an ordinary exposure whose sprocket margins carry the base.
    public struct Frame: Sendable {
        public enum Role: String, Sendable { case image, base, flat, skip }
        public var name: String
        public var url: URL
        public var role: Role
        public init(name: String, url: URL, role: Role) { self.name = name; self.url = url; self.role = role }
    }

    public struct BaseMeasurement: Sendable {
        public var base: [Double]          // [R, G, B]
        public var ratios: BaseRatios
        public var perFrame: [[Double]]
        public var method: Method
        public var quality: Quality
        public var notes: [String]
    }

    public enum CalibrationError: Error, CustomStringConvertible {
        case noMeasurableFrames
        case noRebateFound
        public var description: String {
            switch self {
            case .noMeasurableFrames: return "selection has no measurable frames (only flats or unreadable)"
            case .noRebateFound: return "no usable rebate found in any frame. Include a blank base frame or frames with visible borders"
            }
        }
    }

    // MARK: - JavaScript-shaped helpers

    /// `a.slice().sort()[Math.floor(a.length / 2)]`: the UPPER middle on an even count,
    /// never the mean of the two middles. Six frames is an even count and this choice is
    /// what picks the combined base.
    static func median(_ a: [Double]) -> Double {
        precondition(!a.isEmpty)
        let s = a.sorted()
        return s[s.count / 2]
    }

    /// `(+x.toFixed(n))`.
    ///
    /// Not `(x * 10^n).rounded() / 10^n`, which is the obvious port and is wrong.
    /// `toFixed` rounds the EXACT binary value of the double: 1.2345 is stored as
    /// 1.23449999999999993, so JavaScript writes 1.234, while scaling first gives
    /// 1234.5000000000002 and rounds the other way. Formatting reproduces the exact
    /// rounding. The printf tie rule and the toFixed tie rule differ only where the
    /// scaled value is an exactly representable half, such as 0.125 at two places,
    /// which no measured coefficient here is.
    static func fixed(_ x: Double, _ n: Int) -> Double {
        Double(String(format: "%.\(n)f", x)) ?? x
    }

    @inline(__always) static func sample(_ f: DecodedFrame, _ i: Int, _ c: Int) -> Int {
        Int(f.pixels[i * 3 + c])
    }

    // MARK: - base measurement

    /// Dedicated base frame: center 50 percent, every other pixel, per-channel sums. The
    /// caller combines across frames by total sums, which is the CLI's `--base` rule.
    public static func centerMeanSums(_ f: DecodedFrame) -> (sum: [Double], n: Int) {
        let x0 = Int((Double(f.width) * 0.25).rounded(.down)), x1 = Int((Double(f.width) * 0.75).rounded(.down))
        let y0 = Int((Double(f.height) * 0.25).rounded(.down)), y1 = Int((Double(f.height) * 0.75).rounded(.down))
        var sum = [0.0, 0.0, 0.0]
        var n = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let i = y * f.width + x
                for c in 0..<3 { sum[c] += Double(sample(f, i, c)) }
                n += 1
                x += 2
            }
            y += 2
        }
        return (sum, n)
    }

    /// One frame's sprocket-margin estimate. Frames whose lamp clips read through
    /// `clippedLampEstimate`. Frames with unclipped, periodic sprocket
    /// holes read the rebate below them (`Calibrator+SprocketHoles.swift`).
    public static func rebateEstimate(_ f: DecodedFrame) -> [Double]? {
        rebateReading(f).estimate
    }

    /// The CLI's `--base-rebate` per-frame rule:
    /// outer strips only, the green histogram's largest cluster below the direct-light cap,
    /// clip-guarded channel means. Nil when the strip yields too few clean pixels. It
    /// assumes the lamp through the holes clips. When it does not, the cap is the lamp and
    /// this reads the holes, which is why `rebateReading` checks first.
    public static func clippedLampEstimate(_ f: DecodedFrame) -> [Double]? {
        let h = f.height, w = f.width
        let yTop = Int((Double(h) * rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - rebateMargin)).rounded(.up))
        var hist = [UInt32](repeating: 0, count: 512)
        var cap = 0
        var y = 0
        while y < h {
            if y >= yTop && y < yBot { y += 2; continue }
            var x = 0
            while x < w {
                let v = sample(f, y * w + x, 1)
                hist[min(511, v >> 7)] += 1
                if v > cap { cap = v }
                x += 2
            }
            y += 2
        }
        let capBin = Int((Double(cap) * 0.97 / 128).rounded(.down))
        let bLo = max(1, Int((Double(capBin) * 0.3).rounded(.down)))
        var peak = bLo
        var b = bLo
        while b < min(capBin, 512) {
            if hist[b] > hist[peak] { peak = b }
            b += 1
        }
        let gLo = (peak - 2) * 128, gHi = (peak + 3) * 128
        var sum = [0.0, 0.0, 0.0]
        var n = 0
        y = 0
        while y < h {
            if y >= yTop && y < yBot { y += 2; continue }
            var x = 0
            while x < w {
                let i = y * w + x
                let g = sample(f, i, 1)
                if g < gLo || g >= gHi { x += 2; continue }
                // A channel at the ADC ceiling biases the base low in density. The whole
                // pixel goes, not just that channel, exactly as the TS does.
                let r0 = sample(f, i, 0), b0 = sample(f, i, 2)
                if r0 >= clipGuard || g >= clipGuard || b0 >= clipGuard { x += 2; continue }
                sum[0] += Double(r0); sum[1] += Double(g); sum[2] += Double(b0)
                n += 1
                x += 2
            }
            y += 2
        }
        guard n > minRebatePixels else { return nil }
        return sum.map { $0 / Double(n) }
    }

    /// The user's own base measurement: clip-guarded per-channel means over one square
    /// patch of the PROXY decode, which is where `rebateEstimate` also measures.
    ///
    /// The statistics are `rebateEstimate`'s averaging step and nothing else. No histogram,
    /// no cluster, no bare-light cap: the user has already made the only decision those
    /// exist to make, which is WHERE on the frame the film base is. Guessing a cluster
    /// inside a patch somebody aimed at the rebate would be second-guessing the aim.
    ///
    /// `point` is normalized in decode space, x and y in 0 to 1 with y down, the same space
    /// `Geometry.box` takes a crop in. `radius` is a fraction of the frame WIDTH and the
    /// patch is a square of that half-width, so it covers the same number of pixels each
    /// way whatever the frame's aspect is. Every pixel in the square is read, not every
    /// other one: the patch is small and a mean over all of it is both cheaper to reason
    /// about and slightly better than a strided one.
    ///
    /// Nil when the square falls off the frame entirely or holds fewer than
    /// `minPatchPixels` unclipped pixels. A clipped patch is the case that matters: a pick
    /// on the bare light between the sprockets is at the ADC ceiling, and a mean of ceiling
    /// values is a measurement of the lamp rather than of the film.
    public static func patchEstimate(_ f: DecodedFrame, at point: CGPoint,
                                     radius: Double = 0.02) -> [Double]? {
        guard f.width > 0, f.height > 0 else { return nil }
        guard radius.isFinite, radius > 0 else { return nil }
        let px = Double(point.x), py = Double(point.y)
        guard px.isFinite, py.isFinite else { return nil }

        // At least one pixel of half-width, so a tiny radius on a small frame still reads
        // something rather than returning an empty range.
        let half = max(1.0, Double(f.width) * radius)
        let cx = px * Double(f.width), cy = py * Double(f.height)
        let x0 = max(0, Int((cx - half).rounded(.down)))
        let x1 = min(f.width, Int((cx + half).rounded(.up)))
        let y0 = max(0, Int((cy - half).rounded(.down)))
        let y1 = min(f.height, Int((cy + half).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        // Unclipped sprocket holes: the clip guard below cannot drop the lamp, so the holes
        // go explicitly (`patchBelowHoles`).
        if let holes = sprocketHoles(f) {
            return patchBelowHoles(f, holes: holes, x0: x0, x1: x1, y0: y0, y1: y1)
        }

        var sum = [0.0, 0.0, 0.0]
        var n = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let i = y * f.width + x
                let r = sample(f, i, 0), g = sample(f, i, 1), b = sample(f, i, 2)
                // The whole pixel goes when any channel is at the ceiling, exactly as the
                // strip estimator does it, because a partial pixel biases the ratios.
                if r >= clipGuard || g >= clipGuard || b >= clipGuard { x += 1; continue }
                sum[0] += Double(r); sum[1] += Double(g); sum[2] += Double(b)
                n += 1
                x += 1
            }
            y += 1
        }
        guard n >= minPatchPixels else { return nil }
        return sum.map { $0 / Double(n) }
    }

    /// Roll combine: drop estimates sitting at the sensor ceiling (film base always
    /// attenuates, so a real rebate cannot), then median green and median channel ratios.
    public static func combineRebateEstimates(_ ests: [[Double]]) -> (base: [Double], used: [[Double]], rejected: Int, suspect: Bool) {
        let clean = ests.filter { max($0[0], max($0[1], $0[2])) < ceilingReject }
        var use = ests
        var suspect = false
        if clean.count != ests.count {
            if Double(clean.count) >= max(3.0, Double(ests.count) * 0.25) { use = clean } else { suspect = true }
        }
        var base = [0.0, 0.0, 0.0]
        base[1] = median(use.map { $0[1] })
        base[0] = base[1] * median(use.map { $0[0] / $0[1] })
        base[2] = base[1] * median(use.map { $0[2] / $0[1] })
        return (base, use, ests.count - use.count, suspect)
    }

    /// Worst-channel per-frame ratio spread, `100 * (max - min) / median`, to two decimals.
    /// One estimate has no spread to judge, so it gets the honest middle verdict.
    public static func quality(perFrame: [[Double]]) -> Quality {
        if perFrame.count < 2 { return Quality(framesUsed: perFrame.count, spreadPct: 0, verdict: .fair) }
        func spreadOf(_ vals: [Double]) -> Double {
            let s = vals.sorted()
            let medv = s[s.count / 2]
            return medv > 0 ? 100 * (s[s.count - 1] - s[0]) / medv : .infinity
        }
        let rg = spreadOf(perFrame.map { $0[0] / $0[1] })
        let bg = spreadOf(perFrame.map { $0[2] / $0[1] })
        let spread = fixed(max(rg, bg), 2)
        let verdict: Quality.Verdict = spread <= qualityGoodMax ? .good : spread <= qualityFairMax ? .fair : .poor
        return Quality(framesUsed: perFrame.count, spreadPct: spread, verdict: verdict)
    }

    /// Dedicated base frames if the selection has any, otherwise the sprocket-margin
    /// median over the image frames.
    public static func measureBase(_ frames: [Frame], read: (URL) throws -> DecodedFrame = { try PPM.read($0) }) throws -> BaseMeasurement {
        var notes: [String] = []
        let baseFrames = frames.filter { $0.role == .base }
        let imageFrames = frames.filter { $0.role == .image }
        guard !baseFrames.isEmpty || !imageFrames.isEmpty else { throw CalibrationError.noMeasurableFrames }

        if !baseFrames.isEmpty {
            var total = [0.0, 0.0, 0.0]
            var nTotal = 0
            var perFrame: [[Double]] = []
            for f in baseFrames {
                let (sum, n) = centerMeanSums(try read(f.url))
                perFrame.append(sum.map { $0 / Double(n) })
                for c in 0..<3 { total[c] += sum[c] }
                nTotal += n
            }
            let base = total.map { $0 / Double(nTotal) }
            notes.append("measured from \(baseFrames.count) dedicated base frame(s)")
            return BaseMeasurement(base: base, ratios: BaseRatios(rg: base[0] / base[1], bg: base[2] / base[1]),
                                   perFrame: perFrame, method: .baseFrames, quality: quality(perFrame: perFrame), notes: notes)
        }

        var ests: [[Double]] = []
        for f in imageFrames {
            if let e = rebateEstimate(try read(f.url)) { ests.append(e) }
        }
        guard !ests.isEmpty else { throw CalibrationError.noRebateFound }
        let combined = combineRebateEstimates(ests)
        notes.append("measured from sprocket-margin strips of \(combined.used.count) frame(s)")
        if combined.rejected > 0 { notes.append("\(combined.rejected) direct-light frame estimate(s) rejected") }
        var q = quality(perFrame: combined.used)
        if combined.suspect {
            notes.append("most estimates sat at the sensor ceiling. The measurement is suspect, prefer a blank base frame")
            q.verdict = .poor
        }
        let base = combined.base
        return BaseMeasurement(base: base, ratios: BaseRatios(rg: base[0] / base[1], bg: base[2] / base[1]),
                               perFrame: combined.used, method: .rebateMedian, quality: q, notes: notes)
    }
}

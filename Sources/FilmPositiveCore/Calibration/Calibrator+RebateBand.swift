import Foundation

/// The film edge read as a BAND, for strips with no sprocket holes in them: 120 film, and
/// 35 mm cropped past its holes.
///
/// `stripsShowSprocketHoles` refuses any strip reading without holes behind it, because a
/// strip of picture can look like base by every local photometric measure. A rebate has a
/// shape a picture strip does not: it is one level along the whole width of the frame, and
/// walking inward from the frame edge it ends in a step down to the picture. The walk runs
/// per side, top and bottom, and both must pass.
///
///   1. One level across the width. The outer rows of the strip are averaged per column,
///      a quadratic along the width is fitted to that profile to take out the lamp's
///      falloff (refitted twice on the columns within `patchRebateBand` of the fit, so edge
///      print and the dark ends past the film do not bend it), and at least
///      `bandFlatShare` of the columns must sit within `patchRebateBand` of the fit.
///   2. A step down to the picture. Each row's level is the median of green over the fit.
///      The band runs from the frame edge while that level holds at `bandHoldLevel` or
///      more, for at least the outer rows. Within `bandStepRows` rows after it the level
///      must fall to `bandStepLevel` or less, and the rest of the strip must stay at
///      `bandPictureLevel` or less.
///
/// The reading is then taken from the band rows only, by the old rule's own peak and mean,
/// so the band is read even where the strip as a whole holds more picture than rebate. It
/// needs nothing brighter than the base in the strip, so a uniform 120 edge can be read.
///
/// Measured on a crop ladder (ten frames, each cropped four ways): 8 of 10 crops that
/// keep the rebate but cut the holes read as a band, and 20 of 20 picture crops are refused.
/// The two misses are Harman Azure IMG_0040, whose picture is as thin as its base so there
/// is no step, and Cinestill 800T IMG_0001, whose strip is not one level.
extension Calibrator {
    /// Sampled rows (every other decode row) averaged from the frame edge for the width fit.
    static let bandOuterRows = 4
    /// The share of columns that must sit within `patchRebateBand` of the width fit.
    static let bandFlatShare = 0.6
    /// The band holds while a row's level over the fit is at or above this.
    static let bandHoldLevel = 0.95
    /// The step: within this many sampled rows after the band, the level falls to
    /// `bandStepLevel` or below. Real crops step to 0.13 to 0.71, picture crops that hold a
    /// level for four rows or more never fall below 0.84 inside the same distance.
    static let bandStepRows = 4
    static let bandStepLevel = 0.80
    /// The median level of the strip past the step. The picture stays under the band.
    static let bandPictureLevel = 0.90

    /// The base read from a hole-less rebate band on both strips, or nil when either strip
    /// does not show one.
    public static func rebateBand(_ f: DecodedFrame) -> [Double]? {
        let h = f.height, w = f.width
        guard w > 1, h > 1 else { return nil }
        let yTop = Int((Double(h) * rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - rebateMargin)).rounded(.up))
        let cols = Swift.stride(from: 0, to: w, by: 2).map { $0 }
        // Each strip's rows ordered from the frame edge inward.
        let top = Swift.stride(from: 0, to: yTop, by: 2).map { $0 }
        let bottom = Swift.stride(from: h - 1, through: yBot, by: -2).map { $0 }
        var hist = [Int](repeating: 0, count: 512)
        var bandRows: [Int] = []
        for rows in [top, bottom] {
            guard let n = bandLength(f, rows: rows, cols: cols) else { return nil }
            bandRows += rows[0..<n]
        }
        for y in bandRows {
            for x in cols { hist[min(511, sample(f, y * w + x, 1) >> 7)] += 1 }
        }
        var peak = 1
        for bin in 1..<511 where hist[bin] > hist[peak] { peak = bin }
        let gLo = (peak - 2) * 128, gHi = (peak + 3) * 128
        var sum = [0.0, 0.0, 0.0]
        var n = 0
        for y in bandRows {
            for x in cols {
                let i = y * w + x
                let g = sample(f, i, 1)
                if g < gLo || g >= gHi { continue }
                let r0 = sample(f, i, 0), b0 = sample(f, i, 2)
                if r0 >= clipGuard || g >= clipGuard || b0 >= clipGuard { continue }
                sum[0] += Double(r0); sum[1] += Double(g); sum[2] += Double(b0)
                n += 1
            }
        }
        guard n > minRebatePixels else { return nil }
        return sum.map { $0 / Double(n) }
    }

    /// How many of `rows` (ordered from the frame edge inward) are the rebate band, or nil
    /// when the strip is not one level across the width or does not step down to the picture.
    static func bandLength(_ f: DecodedFrame, rows: [Int], cols: [Int]) -> Int? {
        let w = f.width
        guard rows.count > bandOuterRows + bandStepRows, cols.count > 8 else { return nil }
        var profile = [Double](repeating: 0, count: cols.count)
        for y in rows[0..<bandOuterRows] {
            for (c, x) in cols.enumerated() { profile[c] += Double(sample(f, y * w + x, 1)) }
        }
        profile = profile.map { $0 / Double(bandOuterRows) }
        let t = cols.indices.map { 2 * Double($0) / Double(cols.count - 1) - 1 }
        var keep = [Bool](repeating: true, count: cols.count)
        var fit = [Double](repeating: 0, count: cols.count)
        for _ in 0..<3 {
            guard let q = quadraticFit(t, profile, keep) else { return nil }
            fit = t.map { q[0] + q[1] * $0 + q[2] * $0 * $0 }
            guard let lowest = fit.min(), lowest > 0 else { return nil }
            keep = cols.indices.map { abs(profile[$0] / fit[$0] - 1) <= patchRebateBand }
        }
        guard Double(keep.filter { $0 }.count) >= bandFlatShare * Double(cols.count) else { return nil }

        let level = rows.map { y -> Double in
            let v = cols.indices.map { Double(sample(f, y * w + cols[$0], 1)) / fit[$0] }.sorted()
            return v[v.count / 2]
        }
        var n = 0
        while n < level.count && level[n] >= bandHoldLevel { n += 1 }
        guard n >= bandOuterRows, n + bandStepRows <= level.count,
              let step = level[n..<(n + bandStepRows)].min(), step <= bandStepLevel else { return nil }
        let rest = level[(n + bandStepRows)...].sorted()
        if !rest.isEmpty && rest[rest.count / 2] > bandPictureLevel { return nil }
        return n
    }

    /// Least squares a + b t + c t^2 over the kept points, or nil when the system is singular.
    static func quadraticFit(_ t: [Double], _ v: [Double], _ keep: [Bool]) -> [Double]? {
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var rhs = [0.0, 0.0, 0.0]
        for i in t.indices where keep[i] {
            let p = [1, t[i], t[i] * t[i]]
            for r in 0..<3 {
                for c in 0..<3 { m[r][c] += p[r] * p[c] }
                rhs[r] += p[r] * v[i]
            }
        }
        for col in 0..<3 {
            var pivot = col
            for r in col..<3 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-9 else { return nil }
            m.swapAt(col, pivot); rhs.swapAt(col, pivot)
            for r in 0..<3 where r != col {
                let k = m[r][col] / m[col][col]
                for c in 0..<3 { m[r][c] -= k * m[col][c] }
                rhs[r] -= k * rhs[col]
            }
        }
        return (0..<3).map { rhs[$0] / m[$0][$0] }
    }
}

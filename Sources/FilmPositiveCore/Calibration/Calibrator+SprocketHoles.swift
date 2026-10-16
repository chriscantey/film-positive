import Foundation
import CoreGraphics

/// The film-edge reader for scans where the light through the sprocket holes does NOT clip.
///
/// `clippedLampEstimate` (the original rule) assumes the brightest thing
/// in the outer strips is the lamp at the ADC ceiling. It takes that ceiling as its cap and
/// searches for the largest green cluster between 0.3 and 0.97 of it. When the lamp clips,
/// the rebate lands in that window and the lamp sits above it. When the lamp does not clip,
/// the cap IS the lamp, the rebate falls under the 0.3 floor, and the holes dimmed by
/// light falloff become the peak. A set of 800T and Azure scans read the lamp that way on
/// 31 and 32 of 38 frames.
///
/// This file finds the holes instead of assuming them. It runs only when the strips are
/// essentially unclipped (`lampClipShare`), and its answer replaces the old rule's only when
/// the old rule read hole light. Every roll that clips, and every unclipped frame the old
/// rule already read below the holes, reads exactly what it read before.
///
///   1. The hole cluster is the brightest cluster in the strips' green histogram, cut off
///      from the rest by an empty gap. The hole floor sits in the middle of that gap.
///   2. It must be periodic along both strips: at least four hole-width runs of columns
///      with an even spacing, the same pitch top and bottom, and a pitch a 35 mm frame can
///      have. That separates sprocket holes from a bare rebate (120 film has no holes), a
///      light leak along the film edge, or edge print.
///   3. Hole pixels plus a margin for their blurred edges are dropped, and the rebate is the
///      largest cluster that is left, averaged exactly as the old rule averages.
///
/// If any step fails the frame falls back to `clippedLampEstimate`, so a frame this code
/// does not understand reads exactly what it read before.
extension Calibrator {
    /// A strip with at least this share of its samples at the clip guard has a clipped lamp,
    /// and keeps the old rule. Clipped rolls measure 12.6 to 15 percent (Gold 200, UltraMax,
    /// Treat, and the clipped 800T and Azure frames). A few May Azure frames carry 0.001 to
    /// 0.5 percent from one hot hole and still read the lamp under the old rule, which is
    /// why the gate is a share and not "any clipped pixel".
    public static let lampClipShare = 0.02
    /// A histogram bin at or below this share of the strip's samples counts as empty.
    static let holeGapShare = 0.001
    /// The gap below the hole cluster must be at least this share of the cap's bin, and at
    /// least four bins, before it counts as a gap.
    static let holeGapLength = 0.10
    /// A column is a hole column when at least this share of the strip's rows are hole light.
    static let holeColumnShare = 0.1
    /// Periodic means at least this many hole runs whose spacing varies by no more than
    /// `holeSpacingSpread` (standard deviation over mean).
    static let holeRunsMin = 4
    static let holeSpacingSpread = 0.15
    /// A 35 mm frame spans about eight and a half perforations, so the hole pitch is about
    /// a ninth of the frame width. Anything outside a twelfth to a fifth is not sprocket holes.
    static let holePitchRange = (1.0 / 12)...(1.0 / 5)
    /// Both strips must agree on the pitch to within this share.
    static let holePitchAgreement = 0.10
    /// The hole cluster's share of the strip samples. The May scans run 13 to 38 percent,
    /// the high end on the roll-end frames where bare lamp shows past the film.
    static let holeShareRange = 0.02...0.5
    /// The walk for the gap starts only below the top one percent of the samples, so a few
    /// hot pixels above the holes cannot pass for the gap.
    static let holeTailShare = 0.01
    /// The blurred edge of a hole, as a share of the frame width, dropped with the hole.
    static let holeMarginShare = 0.004
    /// The rebate peak is searched from this share of the cap's bin up to the hole floor.
    static let rebateFloorShare = 0.05
    /// The eyedropper keeps pixels within this share of the frame's rebate green, above and
    /// below, which is wide enough for the lamp's falloff across a frame.
    static let patchRebateBand = 0.10

    /// Which rule read a frame's edge.
    public enum RebatePath: String, Sendable {
        /// The cap rule (`clippedLampEstimate`), kept whenever the lamp clips, no
        /// periodic holes are found, or it already read something below the holes.
        case capRule = "cap-rule"
        /// The rebate read from below explicitly found, unclipped sprocket holes, taken only
        /// where the old rule read the hole light itself.
        case belowHoles = "below-holes"
        /// Refused: one of the rules above returned a reading, but the strips it came from
        /// carry no sprocket holes, so it was a reading of the picture and not of the film
        /// edge (`stripsShowSprocketHoles`).
        case noSprocketHoles = "no-sprocket-holes"
        /// Read from a rebate band with no sprocket holes in it, on both strips (120 film,
        /// or 35 mm cropped past its holes): one level across the width, then a step down
        /// to the picture (`rebateBand`).
        case rebateBand = "rebate-band"
    }

    /// What the sprocket-hole reader found on one frame.
    struct SprocketHoles {
        /// The rebate's clip-guarded channel means.
        let estimate: [Double]
        /// Green at or above this is hole light.
        let holeFloor: Int
        /// The hole margin in full decode pixels.
        let margin: Int
    }

    /// The edge estimate and which rule produced it. `rebateEstimate` is this without the path.
    ///
    /// The old rule's answer stands unless it is hole light: green at or above the hole
    /// floor. Arista 400 has unclipped holes and a rebate thin enough to sit inside the old
    /// rule's window, so the old rule reads it correctly, and it keeps reading it bit for bit.
    ///
    /// Whichever rule answered, the answer is then refused unless the strips show sprocket
    /// holes. Both rules take the top and bottom 9 percent of whatever frame
    /// they are handed and find a cluster there, so on a scan with no film edge in it they
    /// read the picture and call it the base.
    ///
    /// A strip with no holes is still read when both strips show a rebate band: one level
    /// across the width and a step down to the picture (`rebateBand`). The band
    /// is read from its own rows, whichever strip rule answered first.
    public static func rebateReading(_ f: DecodedFrame) -> (estimate: [Double]?, path: RebatePath) {
        let read = stripReading(f)
        if let estimate = read.estimate, stripsShowSprocketHoles(f, baseGreen: estimate[1]) { return read }
        if let band = rebateBand(f) { return (band, .rebateBand) }
        return read.estimate == nil ? read : (nil, .noSprocketHoles)
    }

    /// The two strip rules, before the sprocket hole check.
    public static func stripReading(_ f: DecodedFrame) -> (estimate: [Double]?, path: RebatePath) {
        let old = clippedLampEstimate(f)
        if let holes = sprocketHoles(f), old.map({ $0[1] >= Double(holes.holeFloor) }) ?? true {
            return (holes.estimate, .belowHoles)
        }
        return (old, .capRule)
    }

    /// Lamp light is this many times the reading's green, or brighter. Film base always
    /// attenuates the lamp, so the light through a sprocket hole is brighter than the base
    /// beside it: 1.5 to 4 times on the May 800T and Azure scans, and at the sensor ceiling
    /// on the clipped rolls. 1.3 and 1.5 gave the same verdict on every frame measured.
    public static let lampOverBase = 1.3

    /// Whether a strip reading came from the film edge: both strips carry sprocket holes,
    /// meaning lamp light in evenly spaced runs at a pitch a 35 mm frame has, the same pitch
    /// top and bottom (`holePitch`, `holePitchRange`, `holePitchAgreement`). Lamp light is a
    /// pixel with any channel at the clip guard, or green at `lampOverBase` times the
    /// reading or more, so the test holds whether the lamp clips or not.
    ///
    /// Why holes and not a photometric test of the strip. The crop ladder (ten frames, each
    /// cropped four ways) showed that a strip of picture can look exactly like
    /// base by every local measure tried: its spread, its share of the strip, how much of the
    /// strip is thinner than it, the picture's median against it. Harman Azure IMG_0040
    /// cropped past its rebate reads R/G within 2 percent of its true base. Each of those
    /// rules that refused all twenty picture crops also refused between a quarter and a
    /// third of 229 real full frames, because light falloff makes a real rebate at the edge
    /// darker than thin picture in the middle. Sprocket holes are the one thing a picture
    /// crop cannot have. Measured: 30 of 30 picture crops refused, 397 of 398 real frames
    /// accepted (film-samples, the 114-frame crop battery, the 53-frame half-frame battery).
    /// The one refusal, Cinestill 800T IMG_0026, read R/G 0.53 where the roll's edge reads
    /// 0.90, so it was a wrong reading.
    ///
    /// A film edge with no sprocket holes in it (120 film, a 35 mm scan cropped past the
    /// holes) is not read here. `rebateReading` gives it a second route, the rebate band.
    public static func stripsShowSprocketHoles(_ f: DecodedFrame, baseGreen: Double) -> Bool {
        let h = f.height, w = f.width
        guard w > 1, h > 1, baseGreen.isFinite, baseGreen > 0 else { return false }
        let yTop = Int((Double(h) * rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - rebateMargin)).rounded(.up))
        // The same grid the strip rules sample: every other row of each strip, every other column.
        let top = Swift.stride(from: 0, to: yTop, by: 2).map { $0 }
        let bottom = Swift.stride(from: 0, to: h, by: 2).filter { $0 >= yBot }
        let cols = Swift.stride(from: 0, to: w, by: 2).map { $0 }
        guard !top.isEmpty, !bottom.isEmpty, !cols.isEmpty else { return false }
        let lamp = Int(baseGreen * lampOverBase)
        var pitches: [Double] = []
        for rows in [top, bottom] {
            var count = [Int](repeating: 0, count: cols.count)
            for y in rows {
                for (c, x) in cols.enumerated() {
                    let i = y * w + x
                    if sample(f, i, 1) >= lamp || sample(f, i, 0) >= clipGuard
                        || sample(f, i, 1) >= clipGuard || sample(f, i, 2) >= clipGuard {
                        count[c] += 1
                    }
                }
            }
            let share = count.map { Double($0) / Double(rows.count) }
            guard let pitch = holePitch(share) else { return false }
            pitches.append(pitch / Double(cols.count))
        }
        guard let lo = pitches.min(), let hi = pitches.max() else { return false }
        return holePitchRange.contains(lo) && holePitchRange.contains(hi) && hi - lo <= holePitchAgreement * hi
    }

    /// The strip reader for an unclipped lamp, or nil when the lamp clips, no hole cluster
    /// stands apart, the bright cluster is not periodic, or too little rebate is left.
    static func sprocketHoles(_ f: DecodedFrame) -> SprocketHoles? {
        let h = f.height, w = f.width
        guard w > 1, h > 1 else { return nil }
        let yTop = Int((Double(h) * rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - rebateMargin)).rounded(.up))
        // The same grid the old rule samples: every other row of each strip, every other column.
        let top = Swift.stride(from: 0, to: yTop, by: 2).map { $0 }
        let bottom = Swift.stride(from: 0, to: h, by: 2).filter { $0 >= yBot }
        let cols = Swift.stride(from: 0, to: w, by: 2).map { $0 }
        let strips = [top, bottom].filter { !$0.isEmpty }
        let total = strips.reduce(0) { $0 + $1.count } * cols.count
        guard total > 0 else { return nil }

        var hist = [Int](repeating: 0, count: 512)
        var cap = 0, clipped = 0
        for rows in strips {
            for y in rows {
                for x in cols {
                    let i = y * w + x
                    let g = sample(f, i, 1)
                    hist[min(511, g >> 7)] += 1
                    if g > cap { cap = g }
                    if sample(f, i, 0) >= clipGuard || g >= clipGuard || sample(f, i, 2) >= clipGuard { clipped += 1 }
                }
            }
        }
        guard Double(clipped) < lampClipShare * Double(total) else { return nil }

        // 1. Walk down from the cap to the first long empty run. The bins above it are hole
        // light, the first occupied bin below it is the top of the rebate, and the floor
        // goes halfway between, so dim holes in the gap still count as holes.
        let capBin = min(511, cap >> 7)
        let need = max(4, Int(Double(capBin) * holeGapLength))
        let empty = Double(total) * holeGapShare
        var b = capBin, run = 0, above = 0
        while b >= 1 && Double(above) < holeTailShare * Double(total) { above += hist[b]; b -= 1 }
        while b >= 1 {
            if Double(hist[b]) <= empty {
                run += 1
                if run >= need { break }
            } else {
                run = 0
            }
            b -= 1
        }
        guard run >= need else { return nil }
        let gapTop = b + run
        while b >= 1 && Double(hist[b]) <= empty { b -= 1 }
        let floorBin = (b + 1) + (gapTop - (b + 1)) / 2
        let holeFloor = floorBin * 128
        let holeCount = hist[floorBin...].reduce(0, +)
        guard holeShareRange.contains(Double(holeCount) / Double(total)) else { return nil }

        // 2. Periodic along every strip at one plausible pitch, and the hole masks for step 3.
        var masks: [[Bool]] = []
        var pitches: [Double] = []
        for rows in strips {
            var mask = [Bool](repeating: false, count: rows.count * cols.count)
            var count = [Int](repeating: 0, count: cols.count)
            for (r, y) in rows.enumerated() {
                for (c, x) in cols.enumerated() where sample(f, y * w + x, 1) >= holeFloor {
                    mask[r * cols.count + c] = true
                    count[c] += 1
                }
            }
            let share = count.map { Double($0) / Double(rows.count) }
            guard let pitch = holePitch(share) else { return nil }
            pitches.append(pitch / Double(cols.count))
            masks.append(mask)
        }
        guard let lo = pitches.min(), let hi = pitches.max(), holePitchRange.contains(lo),
              holePitchRange.contains(hi), hi - lo <= holePitchAgreement * hi else { return nil }

        // 3. Drop the holes and their margin, then the old rule's peak and mean on what is left.
        let gridMargin = max(1, Int((Double(w) * holeMarginShare / 2).rounded()))
        masks = zip(strips, masks).map { dilate($1, width: cols.count, height: $0.count, by: gridMargin) }
        var kept = [Int](repeating: 0, count: 512)
        for (rows, mask) in zip(strips, masks) {
            for (r, y) in rows.enumerated() {
                for (c, x) in cols.enumerated() where !mask[r * cols.count + c] {
                    kept[min(511, sample(f, y * w + x, 1) >> 7)] += 1
                }
            }
        }
        let bLo = max(1, Int((Double(capBin) * rebateFloorShare).rounded(.down)))
        guard floorBin > bLo else { return nil }
        var peak = bLo
        for bin in bLo..<floorBin where kept[bin] > kept[peak] { peak = bin }
        let gLo = (peak - 2) * 128, gHi = (peak + 3) * 128
        var sum = [0.0, 0.0, 0.0]
        var n = 0
        for (rows, mask) in zip(strips, masks) {
            for (r, y) in rows.enumerated() {
                for (c, x) in cols.enumerated() where !mask[r * cols.count + c] {
                    let i = y * w + x
                    let g = sample(f, i, 1)
                    if g < gLo || g >= gHi { continue }
                    let r0 = sample(f, i, 0), b0 = sample(f, i, 2)
                    if r0 >= clipGuard || g >= clipGuard || b0 >= clipGuard { continue }
                    sum[0] += Double(r0); sum[1] += Double(g); sum[2] += Double(b0)
                    n += 1
                }
            }
        }
        guard n > minRebatePixels else { return nil }
        return SprocketHoles(estimate: sum.map { $0 / Double(n) }, holeFloor: holeFloor,
                             margin: max(1, Int((Double(w) * holeMarginShare).rounded())))
    }

    /// Sprocket holes along a strip, as their mean spacing in columns, or nil: at least
    /// `holeRunsMin` runs of hole columns, each at least two columns wide, evenly spaced.
    /// Runs more than twice the median width are set aside first, because a bare-lamp region
    /// at the end of a roll is one wide run beside the holes, not a hole.
    public static func holePitch(_ share: [Double]) -> Double? {
        var runs: [(start: Int, end: Int)] = []
        var x = 0
        while x < share.count {
            guard share[x] >= holeColumnShare else { x += 1; continue }
            var e = x
            while e < share.count && share[e] >= holeColumnShare { e += 1 }
            if e - x >= 2 { runs.append((x, e)) }
            x = e
        }
        guard runs.count >= holeRunsMin else { return nil }
        let widths = runs.map { $0.end - $0.start }.sorted()
        let median = widths[widths.count / 2]
        let holes = runs.filter { $0.end - $0.start <= 2 * median }
        guard holes.count >= holeRunsMin else { return nil }
        let centres = holes.map { Double($0.start + $0.end) / 2 }
        let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard mean > 0 else { return nil }
        let sd = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
        return sd / mean <= holeSpacingSpread ? mean : nil
    }

    /// Square dilation of a row-major mask, done as a horizontal pass then a vertical one.
    static func dilate(_ mask: [Bool], width: Int, height: Int, by r: Int) -> [Bool] {
        var across = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for xx in max(0, x - r)...min(width - 1, x + r) { across[y * width + xx] = true }
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where across[y * width + x] {
                for yy in max(0, y - r)...min(height - 1, y + r) { out[yy * width + x] = true }
            }
        }
        return out
    }

    /// The eyedropper on a frame with unclipped holes: the square minus the holes and their
    /// margin, keeping only pixels near the frame's own rebate green. The old patch trusted
    /// the aim and relied on the clip guard to drop the lamp, which only works when the lamp
    /// clips. On the May 800T scans a click on the rebate between the holes read within 0.02
    /// of the base about one time in four. Nil when nothing clean is left.
    static func patchBelowHoles(_ f: DecodedFrame, holes: SprocketHoles,
                                x0: Int, x1: Int, y0: Int, y1: Int) -> [Double]? {
        let m = holes.margin
        let ex0 = max(0, x0 - m), ex1 = min(f.width, x1 + m)
        let ey0 = max(0, y0 - m), ey1 = min(f.height, y1 + m)
        let bw = ex1 - ex0, bh = ey1 - ey0
        var mask = [Bool](repeating: false, count: bw * bh)
        for y in ey0..<ey1 {
            for x in ex0..<ex1 where sample(f, y * f.width + x, 1) >= holes.holeFloor {
                mask[(y - ey0) * bw + (x - ex0)] = true
            }
        }
        mask = dilate(mask, width: bw, height: bh, by: m)
        let centre = holes.estimate[1]
        let lo = centre * (1 - patchRebateBand), hi = centre * (1 + patchRebateBand)
        var sum = [0.0, 0.0, 0.0]
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 where !mask[(y - ey0) * bw + (x - ex0)] {
                let i = y * f.width + x
                let r = sample(f, i, 0), g = sample(f, i, 1), b = sample(f, i, 2)
                if r >= clipGuard || g >= clipGuard || b >= clipGuard { continue }
                if Double(g) < lo || Double(g) >= hi { continue }
                sum[0] += Double(r); sum[1] += Double(g); sum[2] += Double(b)
                n += 1
            }
        }
        guard n >= minPatchPixels else { return nil }
        return sum.map { $0 / Double(n) }
    }
}

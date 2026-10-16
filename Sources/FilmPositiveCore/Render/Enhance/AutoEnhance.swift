import Foundation
import ImageIO
import CoreGraphics
import FilmSidecar

/// Auto Enhance: the wand in the Enhance section.
///
/// **What it reads.** The developed, cropped frame before any enhance, sampled to about a
/// 512 pixel long edge. **What it writes.** Four ordinary sliders (Black Point, Brightness,
/// Highlights, Saturation) and Vibrance tied to Saturation, and Warmth and Tint from the cast
/// neutralizer plus a warm offset (`wandReadsColour`), so every choice is on screen and one
/// Undo takes it back. The app runs it from identity and writes the result over identity, so
/// a wand press leaves nothing else in the enhance layer (`AppModel.autoEnhanceSelection`).
/// `propose` itself still keeps whatever `current` carries, which is how the fitting tools
/// and tests call it.
///
/// **The one place it holds back** is clipping. Neither end of the histogram may gain more
/// than half a percentage point of clipped pixels (any channel at or below 1/255, or at or
/// above 254/255). A dark-end breach scales Black Point back on its own. A white-end breach
/// scales back what pushes the top (a positive Brightness, a positive Highlights, and the
/// color lift).
///
/// A frame with no color gets no color lift.
public enum AutoEnhance {

    /// The sliders the wand owns.
    public struct Proposal: Equatable, Sendable {
        public var blackPoint: Double
        public var brightness: Double
        public var highlights: Double
        public var saturation: Double
        public var vibrance: Double
        /// Set by the cast neutralizer, and by the wand when it reads color. Nil leaves the
        /// frame's own warmth and tint alone.
        public var warmth: Double?
        public var tint: Double?
        /// The wand's tone style, set before the solve and held there (`toneStyle`).
        public var shadows: Double
        public var exposure: Double

        public static let none = Proposal(blackPoint: 0, brightness: 0, highlights: 0, saturation: 0, vibrance: 0)

        public init(blackPoint: Double, brightness: Double, highlights: Double, saturation: Double, vibrance: Double,
                    warmth: Double? = nil, tint: Double? = nil, shadows: Double = 0, exposure: Double = 0) {
            self.blackPoint = blackPoint; self.brightness = brightness; self.highlights = highlights
            self.saturation = saturation; self.vibrance = vibrance; self.warmth = warmth; self.tint = tint
            self.shadows = shadows; self.exposure = exposure
        }

        public func scaled(_ k: Double) -> Proposal {
            Proposal(blackPoint: blackPoint * k, brightness: brightness * k, highlights: highlights * k,
                     saturation: saturation * k, vibrance: vibrance * k, warmth: warmth, tint: tint,
                     shadows: shadows * k, exposure: exposure * k)
        }

        /// `base` with the wand's sliders set to this proposal.
        public func applied(to base: EnhanceSettings) -> EnhanceSettings {
            var s = base
            s.blackPoint = blackPoint; s.brightness = brightness; s.highlights = highlights
            s.saturation = saturation; s.vibrance = vibrance
            s.shadows = shadows; s.exposure = exposure
            if let warmth { s.warmth = warmth }
            if let tint { s.tint = tint }
            return s
        }
    }

    // MARK: statistics, one definition shared by the rule, the solver and the tests

    public struct FrameStats: Equatable, Sendable, Codable {
        /// Rec.709 luma percentiles and mean, display-referred, 0 to 1.
        public var p1, p50, p99, meanLuma: Double
        /// Mean HSV saturation `(max - min) / max` over every pixel.
        public var meanSat: Double
        /// Share of pixels with any channel that an 8-bit file stores at or below 1, or at or
        /// above 254.
        public var clipLow, clipHigh: Double
        /// Luma p75, the upper midtones.
        public var p75: Double

        public init(p1: Double, p50: Double, p99: Double, meanLuma: Double, meanSat: Double, clipLow: Double, clipHigh: Double, p75: Double = 0) {
            self.p1 = p1; self.p50 = p50; self.p99 = p99; self.meanLuma = meanLuma
            self.meanSat = meanSat; self.clipLow = clipLow; self.clipHigh = clipHigh; self.p75 = p75
        }

        /// Below this there is no color to lift: a black-and-white frame reads about 0.01.
        public static let colourFloor = 0.04
        public var hasColour: Bool { meanSat >= Self.colourFloor }
    }

    public static func stats(_ f: DecodedFrame) -> FrameStats {
        let n = f.width * f.height
        guard n > 0 else { return FrameStats(p1: 0, p50: 0, p99: 0, meanLuma: 0, meanSat: 0, clipLow: 0, clipHigh: 0) }
        var lumas = [Float](repeating: 0, count: n)
        var sat = 0.0, lumaSum = 0.0, lo = 0, hi = 0
        // Half a code inside each end: the export writes 8 bits, and a value at 253.5/255
        // rounds to 254 there, so counting from 254/255 here would miss pixels the file clips
        // (11 of 116 manifest frames read over budget at full size).
        let low = UInt16(65535.0 * 1.5 / 255.0), high = UInt16((65535.0 * 253.5 / 255.0).rounded(.up))
        f.pixels.withUnsafeBufferPointer { px in
            for i in 0..<n {
                let ri = px[i * 3], gi = px[i * 3 + 1], bi = px[i * 3 + 2]
                let r = Float(ri) / 65535, g = Float(gi) / 65535, b = Float(bi) / 65535
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas[i] = y; lumaSum += Double(y)
                let mx = max(r, g, b), mn = min(r, g, b)
                if mx > 0 { sat += Double((mx - mn) / mx) }
                if min(ri, gi, bi) <= low { lo += 1 }
                if max(ri, gi, bi) >= high { hi += 1 }
            }
        }
        lumas.sort()
        func pct(_ q: Double) -> Double { Double(lumas[min(n - 1, Int(q * Double(n - 1)))]) }
        return FrameStats(p1: pct(0.01), p50: pct(0.5), p99: pct(0.99), meanLuma: lumaSum / Double(n),
                          meanSat: sat / Double(n), clipLow: Double(lo) / Double(n), clipHigh: Double(hi) / Double(n), p75: pct(0.75))
    }

    // MARK: cast, read on the near-grey midtones

    /// sRGB (display, 0 to 1) to CIE L*a*b* (D65).
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// The pixels that SHOULD be grey if the frame had no cast: midtones (L* 30 to 70) with
    /// little color (chroma under 12). Chosen on the develop-only frame and held fixed, so a
    /// before and after are read on the same pixels.
    public static func greyMask(_ f: DecodedFrame) -> [Bool] {
        (0..<(f.width * f.height)).map { i in
            let (l, a, b) = lab(Float(f.pixels[i * 3]) / 65535, Float(f.pixels[i * 3 + 1]) / 65535, Float(f.pixels[i * 3 + 2]) / 65535)
            return l > 30 && l < 70 && hypotf(a, b) < 12
        }
    }

    /// Mean a* and b* over the mask: the frame's cast. Positive b* is yellow, negative blue;
    /// positive a* is magenta, negative green. Nil when fewer than 0.5% of pixels qualify.
    public static func cast(_ f: DecodedFrame, mask: [Bool]) -> (a: Double, b: Double)? {
        var sa = 0.0, sb = 0.0, n = 0
        for i in 0..<(f.width * f.height) where mask[i] {
            let (_, a, b) = lab(Float(f.pixels[i * 3]) / 65535, Float(f.pixels[i * 3 + 1]) / 65535, Float(f.pixels[i * 3 + 2]) / 65535)
            sa += Double(a); sb += Double(b); n += 1
        }
        guard n * 200 >= f.width * f.height else { return nil }
        return (sa / Double(n), sb / Double(n))
    }

    /// Mean |hue-angle change| in degrees between two same-size frames, over pixels with Lab
    /// chroma above 8 in both: how far the color moved.
    public static func hueShift(_ a: DecodedFrame, _ b: DecodedFrame) -> Double {
        var s = 0.0, n = 0
        for i in 0..<(a.width * a.height) {
            let (_, a0, b0) = lab(Float(a.pixels[i * 3]) / 65535, Float(a.pixels[i * 3 + 1]) / 65535, Float(a.pixels[i * 3 + 2]) / 65535)
            let (_, a1, b1) = lab(Float(b.pixels[i * 3]) / 65535, Float(b.pixels[i * 3 + 1]) / 65535, Float(b.pixels[i * 3 + 2]) / 65535)
            guard hypotf(a0, b0) > 8, hypotf(a1, b1) > 8 else { continue }
            var d = Double(atan2f(b1, a1) - atan2f(b0, a0)) * 180 / .pi
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            s += abs(d); n += 1
        }
        return n == 0 ? 0 : s / Double(n)
    }

    // MARK: the rule, its strength read from this frame

    /// The change a good starting edit makes to a frame's luma p1, mean luma, luma p99 and mean
    /// saturation, as a function of that frame's own statistics. These lines are the APP's
    /// opinion of a good starting edit, not a fact about any film: least-squares fits to one
    /// person's own edits of 201 frames from two rolls, inputs [1, p1, p50, p99, meanSat],
    /// R² 0.40, 0.39, 0.23 and 0.26.
    ///
    /// The saturation line is fitted on the same edits read against the Processed file each
    /// edit started from (edit minus jxl) rather than against a fresh re-develop, which removes
    /// the develop drift from its target. On a Kodak Gold roll finished in Positive, a roll it
    /// never saw, it brings the wand's landed saturation closer to the person's (mean absolute
    /// 0.053 to 0.040).
    public struct Targets: Equatable, Sendable {
        public var dP1, dMeanLuma, dP99, dSat: Double
        /// The upper-midtone target, luma p75's change. Nil: no such target.
        public var dP75: Double? = nil
    }

    static let dP1Fit: [Double] = [-0.0099, -0.3510, -0.0038, -0.0543, 0.2297]
    static let dMeanLumaFit: [Double] = [0.2483, -0.3312, -0.0936, -0.1379, 0.0222]
    static let dP99Fit: [Double] = [0.5929, -0.1116, -0.0124, -0.5968, -0.0025]
    static let dSatFit: [Double] = [0.7015, 0.3876, -0.1932, -0.4243, -0.4043]

    /// Added to the three tone targets (dP1, dMeanLuma, dP99) on a black-and-white stock.
    /// The lines were fitted to color frames only. Zero until a held-out residual on a
    /// black-and-white roll says otherwise.
    public static let monoToneBias: [Double] = [0, 0, 0]

    /// On a color stock, luma p75 is asked to move by the mean-luma target plus this, an
    /// upper-midtone shape: on a Kodak Gold roll finished in Positive the wand sat 1.2 to 1.8
    /// L* brighter than the person's edits in the upper midtones (deciles 6 to 8) under every
    /// slider route tried. Nil: no p75 target. Never applied on a black-and-white stock.
    public static let p75Shape: Double? = nil

    public static func targets(_ s: FrameStats, mono: Bool = false, p75Shape shape: Double? = p75Shape) -> Targets {
        let x = [1, s.p1, s.p50, s.p99, s.meanSat]
        func dot(_ c: [Double]) -> Double { zip(c, x).map(*).reduce(0, +) }
        let b = mono ? monoToneBias : [0, 0, 0]
        let dMean = dot(dMeanLumaFit) + b[1]
        return Targets(dP1: dot(dP1Fit) + b[0], dMeanLuma: dMean, dP99: dot(dP99Fit) + b[2],
                       dSat: s.hasColour && !mono ? dot(dSatFit) : 0,
                       dP75: mono ? nil : shape.map { dMean + $0 })
    }

    /// The wand's tone style: Shadows and Exposure per unit of the mean-luma lift the frame's
    /// target asks for (`Targets.dMeanLuma`), set before the solve and held there so the solve
    /// lands the same p1, mean luma and p99 by shadow lift and gain rather than a midtone
    /// Brightness lift. Both are 0, so the style is off and Brightness carries the lift. Zero
    /// on a black-and-white stock in any case.
    public static let toneStyle: (shadows: Double, exposure: Double) = (0, 0)

    /// The Shadows and Exposure a frame's targets get from style coefficients `c`, inside -1...1.
    public static func style(_ c: (shadows: Double, exposure: Double), for t: Targets) -> (shadows: Double, exposure: Double) {
        func box(_ v: Double) -> Double { min(max(v, -1), 1) }
        return (box(c.shadows * t.dMeanLuma), box(c.exposure * t.dMeanLuma))
    }

    /// On a color stock, the Brightness the wand holds while Shadows answers for Black Point.
    /// Black Point's levels stretch pulls the midtones down, and on a Kodak Gold roll finished
    /// in Positive the person's edits buy them back with Shadows (median +0.35) and run
    /// Brightness slightly negative (-0.18), where the wand buys them back with Brightness
    /// (+0.50). With a value here the solve frees Shadows in Brightness's place and holds
    /// Brightness at it. Nil: Brightness is free and Shadows stays at the style. Never applied
    /// on a black-and-white stock.
    public static let brightnessHold: Double? = nil

    /// Vibrance rides with Saturation at a measured ratio (median +0.07 against +0.08).
    public static let vibrancePerSaturation = 0.9

    /// The slider box the solve stays inside: the wand never writes past it. Black Point,
    /// Brightness, Highlights, Saturation, Shadows.
    static let lower = [-0.5, -1.0, -1.0, -0.5, -1.0], upper = [2.0, 2.0, 1.0, 1.5, 1.0]

    /// Our sliders that land this frame on its targets: damped Gauss-Newton over Black
    /// Point, Brightness, Highlights and Saturation (Vibrance tied), on the frame as given,
    /// through the real enhance chain. No guard here; `guarded` is applied after.
    ///
    /// `blackPoint`, when given, is held there and the darkest-1% target is dropped: that is
    /// how the clip guard re-solves the rest of the frame after it has had to cap the dark end,
    /// so Brightness is not left lifting midtones that Black Point no longer pulls down.
    ///
    /// `holdBrightness`, when given, holds Brightness there and frees Shadows in its place,
    /// starting from the style's Shadows (`brightnessHold`).
    public static func solve(_ frame: DecodedFrame, base: EnhanceSettings, targets t: Targets,
                             blackPoint fixedBlack: Double? = nil, style: (shadows: Double, exposure: Double) = (0, 0),
                             holdBrightness: Double? = nil,
                             render: (DecodedFrame, EnhanceSettings) throws -> DecodedFrame) rethrows -> Proposal {
        let s0 = stats(try render(frame, Proposal.none.applied(to: base)))
        let goal = [s0.p1 + t.dP1, s0.meanLuma + t.dMeanLuma, s0.p99 + t.dP99, s0.meanSat + t.dSat, s0.p75 + (t.dP75 ?? 0)]
        // The free sliders, as indices into x: Black Point unless held, then Brightness (or
        // Shadows while Brightness is held), Highlights, and Saturation when the frame has color.
        let vars = (fixedBlack == nil ? [0] : []) + [holdBrightness == nil ? 1 : 4, 2] + (t.dSat == 0 ? [] : [3])
        let rows = (fixedBlack == nil ? [0] : []) + [1, 2, 3] + (t.dP75 == nil ? [] : [4])
        func proposal(_ x: [Double]) -> Proposal {
            Proposal(blackPoint: x[0], brightness: x[1], highlights: x[2], saturation: x[3],
                     vibrance: x[3] * vibrancePerSaturation, shadows: x[4], exposure: style.exposure)
        }
        func residual(_ x: [Double]) throws -> [Double] {
            let s = stats(try render(frame, proposal(x).applied(to: base)))
            // The darkest 1% counts three times: our Black Point and Brightness pull against
            // each other, and unweighted the solve overshoots p1 by half again (1.54x the
            // reference mean move over the manifest) to buy the last of the midtone target.
            let weight = [3.0, 1.0, 1.0, 1.0, 1.0]
            let all = zip([s.p1, s.meanLuma, s.p99, s.meanSat, s.p75], goal).enumerated().map { ($1.0 - $1.1) * weight[$0] }
            return rows.map { all[$0] }
        }
        let free = vars.count, R = rows.count
        var x = [fixedBlack ?? 0.0, holdBrightness ?? 0.0, 0.0, 0.0, style.shadows]
        var r = try residual(x)
        var lambda = 1e-3
        for _ in 0..<10 {
            let norm = r.map { $0 * $0 }.reduce(0, +)
            if norm < 1e-7 { break }
            var J = [[Double]](repeating: [Double](repeating: 0, count: free), count: R)
            for (j, v) in vars.enumerated() {
                // Core Image's shadow adjust does nothing below 0.07 of the slider, a dead zone a
                // 0.03 step from 0 could not see. The enhance chain crossfades through it, so one
                // step serves every slider.
                let h = 0.03
                var xp = x
                xp[v] = min(max(x[v] + h, lower[v]), upper[v])
                if xp[v] == x[v] { xp[v] = max(x[v] - h, lower[v]) }
                let d = xp[v] - x[v]
                guard d != 0 else { continue }
                let rp = try residual(xp)
                for i in 0..<R { J[i][j] = (rp[i] - r[i]) / d }
            }
            var M = [[Double]](repeating: [Double](repeating: 0, count: free + 1), count: free)
            for a in 0..<free {
                for b in 0..<free { for i in 0..<R { M[a][b] += J[i][a] * J[i][b] } }
                for i in 0..<R { M[a][free] -= J[i][a] * r[i] }
                M[a][a] += lambda * (M[a][a] + 1e-6)
            }
            for c in 0..<free {
                let piv = (c..<free).max { abs(M[$0][c]) < abs(M[$1][c]) }!
                M.swapAt(c, piv)
                guard abs(M[c][c]) > 1e-12 else { continue }
                for rr in 0..<free where rr != c {
                    let f = M[rr][c] / M[c][c]
                    for k in c...free { M[rr][k] -= f * M[c][k] }
                }
            }
            var xn = x
            for (j, v) in vars.enumerated() where abs(M[j][j]) > 1e-12 { xn[v] = min(max(x[v] + M[j][free] / M[j][j], lower[v]), upper[v]) }
            let rn = try residual(xn)
            if rn.map({ $0 * $0 }).reduce(0, +) < norm { x = xn; r = rn; lambda = max(lambda / 3, 1e-6) }
            else { lambda *= 10; if lambda > 1e3 { break } }
        }
        return proposal(x)
    }

    // MARK: the clip guard

    /// How far past the frame's own clipping the wand may push each end, as a share of the
    /// frame. The dark end allows 3.5 points: the edits the lines were fitted to clip a median
    /// 3.7 points more at the black end, and at 0.5 the budget bound on 186 of 201 frames and
    /// took most of the fitted Black Point away. The edits' p90 tail, 21.7 points, stays held.
    /// The white end stays at 0.5 points.
    public static let clipBudgetDark = 0.035
    public static let clipBudgetWhite = 0.005

    /// The proposal with each end brought inside its budget, giving up as little as it can:
    /// Black Point alone answers for the dark end, then every upward push (Black Point's
    /// stretch among them) for the white end, each scaled to the largest fraction that
    /// holds, found by bisection.
    public static func guarded(_ p: Proposal, on frame: DecodedFrame, base: EnhanceSettings,
                               budget: (dark: Double, white: Double) = (clipBudgetDark, clipBudgetWhite),
                               render: (DecodedFrame, EnhanceSettings) throws -> DecodedFrame) rethrows -> Proposal {
        let before = stats(try render(frame, Proposal.none.applied(to: base)))
        func measure(_ q: Proposal) throws -> FrameStats { stats(try render(frame, q.applied(to: base))) }
        /// The largest k in 0...1 for which `make(k)` holds `over`, by bisection (seven
        /// halvings, about 1% of the move), or 1 when the full move already holds.
        func largest(_ make: (Double) -> Proposal, over: (FrameStats) -> Bool) throws -> Proposal {
            if try !over(measure(make(1))) { return make(1) }
            var lo = 0.0, hi = 1.0
            for _ in 0..<7 {
                let mid = (lo + hi) / 2
                if try over(measure(make(mid))) { hi = mid } else { lo = mid }
            }
            return make(lo)
        }
        let darkOver = { (s: FrameStats) in s.clipLow - before.clipLow > budget.dark }
        let whiteOver = { (s: FrameStats) in s.clipHigh - before.clipHigh > budget.white }
        // Dark end: Black Point first.
        var out = try largest({ k in var q = p; q.blackPoint = p.blackPoint * k; return q }, over: darkOver)
        // Still over with Black Point gone: the color lift and a darkening Brightness can
        // push a channel of a dark, tinted pixel to zero too.
        let afterBlack = out
        out = try largest({ k in
            var q = afterBlack
            if p.brightness < 0 { q.brightness = p.brightness * k }
            if p.exposure < 0 { q.exposure = p.exposure * k }
            if p.shadows < 0 { q.shadows = p.shadows * k }
            q.saturation = p.saturation * k; q.vibrance = p.vibrance * k
            return q
        }, over: darkOver)
        // White end: everything that pushes the top up, Black Point included, because its
        // levels stretch lifts the brightest pixels as it pulls the darkest down.
        let kept = out
        out = try largest({ k in
            var q = kept
            if kept.brightness > 0 { q.brightness = kept.brightness * k }
            if kept.highlights > 0 { q.highlights = kept.highlights * k }
            if kept.exposure > 0 { q.exposure = kept.exposure * k }
            q.saturation = kept.saturation * k; q.vibrance = kept.vibrance * k
            q.blackPoint = kept.blackPoint * k
            return q
        }, over: whiteOver)
        return out
    }

    // MARK: the whole wand

    /// Whether the wand reads color as well as tone. The ONE switch: on, the wand first
    /// balances the frame with the neutralizer plus the warm offset below, solves Vibrance and
    /// Saturation with the rest on that balanced frame, then writes Warmth and Tint read again
    /// through the tone it chose. Off, the wand leaves Warmth and Tint as the frame has them.
    public static let wandReadsColour = true

    /// The CIELAB D50 b* the wand leaves a neutral surface at: a little warm of neutral. Half of
    /// the 5 a held-out sweep over hand edits chose (the lowest color error of the offsets that
    /// leave Warmth free on at least 80 percent of frames in every fold), because the wand at 5
    /// reads too warm in use. Those edits put
    /// former greys at +16.8 as a median, but that is one session's warm greys (+18.0) against
    /// another's nearly neutral ones (+9.6), and at 10 or more Warmth sits on its limit for most
    /// frames. At 0 the wand leaves greys neutral. The Neutralize button does not use it.
    public static let wandGreyB = 2.5

    /// Sample, read the statistics, set this frame's targets, solve our sliders onto them,
    /// scale by `intensity` (0 to 1), then hold both ends of the histogram to the clip
    /// budget. Every value comes from this frame. `developed` is the frame after develop and
    /// crop, before enhance. `current` is what the frame carries now: every slider the wand
    /// does not own is kept. With `readsColour` it also writes Warmth and Tint (see
    /// `wandReadsColour`). Without it the frame's own warmth and tint stay as they are.
    ///
    /// `mono` is the frame's stock being black and white. Such a frame gets no color step
    /// and no Saturation or Vibrance, whatever tint the scan carries, and its tone targets take
    /// `monoToneBias`. The app passes it from the frame's effective stock.
    public static func propose(for developed: DecodedFrame, current: EnhanceSettings,
                               intensity: Double = 1, clipGuard: Bool = true, readsColour: Bool = wandReadsColour,
                               mono: Bool = false, holdBrightness: Double? = brightnessHold,
                               render: (DecodedFrame, EnhanceSettings) throws -> DecodedFrame = { try CoreImageEnhance().apply($0, settings: $1) }) rethrows -> Proposal {
        let readsColour = readsColour && !mono
        let k = min(max(intensity, 0), 1)
        let carried = current
        var current = current
        // The color step, in two reads. The first reads the frame with the wand's own sliders
        // taken out, as the solve does, and balances the frame the tone and color solve below
        // then works on. The second reads again through the tone the solve chose, because that
        // is the frame `CITemperatureAndTint` will act on in the finished edit: read before the
        // solve, a Brightness the solve then adds moves Party's near-grey b* from the +5 asked
        // for to +8. Both reads ignore the frame's own Warmth
        // and Tint, so pressing the wand again asks for the same values.
        var colour = false
        if readsColour, k > 0,
           let n = try neutralisation(developed, current: Proposal.none.applied(to: current), warmOffset: wandGreyB, offsetRange: wandWarmRange, render: render) {
            colour = true
            current.warmth = n.warmth; current.tint = n.tint
        }
        func withColour(_ p: Proposal) throws -> Proposal {
            guard colour else { return p }
            var p = p
            let n = try neutralisation(developed, current: p.applied(to: current), warmOffset: wandGreyB, offsetRange: wandWarmRange, render: render)
            let w = n?.warmth ?? current.warmth, t = n?.tint ?? current.tint
            p.warmth = carried.warmth + k * (w - carried.warmth); p.tint = carried.tint + k * (t - carried.tint)
            return p
        }
        let proxy = sampled(developed, longEdge: 512)
        let base = Proposal.none.applied(to: current)
        let s = stats(try render(proxy, base))
        let t = targets(s, mono: mono)
        let style = mono ? (shadows: 0.0, exposure: 0.0) : Self.style(toneStyle, for: t)
        let hold = mono ? nil : holdBrightness
        var solved = try solve(proxy, base: current, targets: t, style: style, holdBrightness: hold, render: render)
        // Without the guard: the strength exactly as the rule asks. Only the manifest
        // regression turns it off, to measure the rule apart from what the guard costs.
        guard clipGuard else { return try withColour(solved.scaled(k)) }
        // The dark end first, because Black Point and Brightness pull against each other: if
        // the budget caps Black Point, the rest is solved again around the capped value
        // rather than left lifting midtones for a pull that no longer happens.
        let capped = try guarded(solved, on: proxy, base: current, render: render)
        if capped.blackPoint < solved.blackPoint - 1e-9 {
            solved = try solve(proxy, base: current, targets: t, blackPoint: capped.blackPoint, style: style, holdBrightness: hold, render: render)
        }
        solved.blackPoint *= k; solved.brightness *= k; solved.highlights *= k
        solved.saturation *= k; solved.vibrance *= k; solved.shadows *= k; solved.exposure *= k
        return try withColour(try guarded(solved, on: proxy, base: current, render: render))
    }

    // MARK: the cast neutralizer, its own button beside the Color group
    //
    // **What it reads.** The fitted estimator (`AdaptiveColour`, lowChroma: the mean a* and b*
    // of the midtones, L* 25 to 85, with C* under 10), with its strength, tint share, cap and
    // fade. Nothing a button changes may be hidden, so the reading lands on the Warmth and Tint
    // sliders.
    //
    // The estimator removes about half the a* reading and a little more than the b* reading,
    // never moves a neutral more than 10 C* (the cap), and leaves a cast of 30 C* or more alone
    // as the scene's own color (the fade). The reading is made on the frame WITHOUT its Warmth
    // and Tint, so the two values it writes are absolute and pressing it twice writes the same
    // values.

    /// The estimator's method constants, its fitted set.
    public static let castMethod = AdaptiveColour.Parameters.default

    /// The neutral solve writes Warmth and Tint inside this span, for the Neutralize button and
    /// for the neutral half of the wand's color step. The controls rest at -1 to 1 and take any
    /// typed value past it (the track rescales), and a set of sidecars reaches Warmth 1.44
    /// (Oregon), so the bound is 1.5 either way. It is also the solve's step limit: the damped
    /// Newton below takes only a step that brings the patch closer and has no line search, so
    /// at 3 either way its first full step on a strong cast overshoots, is refused, and the
    /// solve stops at zero (AdaptiveColourTests' sunset control).
    public static let wbRange = -1.5...1.5

    /// The span the wand's warm offset may move Warmth to, after the neutral solve. The warm
    /// direction is the weaker one (`warmthKelvinSpan`), which is where the offset needs the room:
    /// with the fitted lines, 34 of 201 held-out frames sat on 1.5 at the chosen offset, and 3
    /// frees them. The Neutralize button never uses it.
    public static let wandWarmRange = -3.0...3.0

    /// The settings that render the frame exactly as the chain's white balance step receives it:
    /// every tone slider before that step (Exposure, Radiance, Shadows, Highlights, Black Point,
    /// Contrast, Brightness), and nothing from Warmth on. The cast is read there because that is
    /// the input `CITemperatureAndTint` will act on, so the solve below is exact for it.
    public static func whiteBalanceInput(_ s: EnhanceSettings) -> EnhanceSettings {
        var t = EnhanceSettings()
        t.exposure = s.exposure; t.radiance = s.radiance; t.shadows = s.shadows; t.highlights = s.highlights
        t.blackPoint = s.blackPoint; t.contrast = s.contrast; t.brightness = s.brightness
        return t
    }

    /// What the neutralizer read and wrote, for the button, the wand, the tests and the harness.
    public struct Neutralisation: Equatable, Sendable {
        /// The estimate, CIELAB D50 at the white balance step's input.
        public var reading: AdaptiveColour.Reading
        /// The fraction of the cast removed (strength, cap and fade).
        public var fraction: Double
        /// Where a neutral surface should land (CIELAB D50), from `AdaptiveColour.target`.
        public var goalL, goalA, goalB: Double
        /// Warmth and Tint that land the neutral patch on the goal, as closely as the filter can.
        public var neutralWarmth, neutralTint: Double
        /// The patch through those two, CIELAB D50.
        public var neutralA, neutralB: Double
        /// What is written. The same as the neutral pair unless a warm offset was asked for
        /// (the wand's), which moves Warmth alone.
        public var warmth, tint: Double
        /// The patch through the written pair.
        public var landedA, landedB: Double
    }

    /// A small flat patch of one CIELAB D50 color, as a 16-bit sRGB frame.
    public static func patch(_ l: Double, _ a: Double, _ b: Double) -> DecodedFrame {
        let (r, g, bb) = AdaptiveColour.rgb(l, a, b)
        func enc(_ v: Double) -> UInt16 {
            let c = min(max(v, 0), 1)
            return UInt16(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 65535).rounded())
        }
        let px = [enc(r), enc(g), enc(bb)]
        return DecodedFrame(width: 8, height: 8, pixels: (0..<64).flatMap { _ in px })
    }

    /// Mean CIELAB D50 of a 16-bit sRGB frame, the estimator's own Lab.
    public static func meanLabD50(_ f: DecodedFrame) -> (l: Double, a: Double, b: Double) {
        var s = (0.0, 0.0, 0.0)
        let n = f.width * f.height
        for i in 0..<n {
            func dec(_ u: UInt16) -> Double { let v = Double(u) / 65535; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let (l, a, b) = AdaptiveColour.lab(dec(f.pixels[i * 3]), dec(f.pixels[i * 3 + 1]), dec(f.pixels[i * 3 + 2]))
            s.0 += l; s.1 += a; s.2 += b
        }
        return (s.0 / Double(n), s.1 / Double(n), s.2 / Double(n))
    }

    /// The whole neutralizer. Reads the cast on `developed` (after develop and crop, before
    /// enhance) through the frame's own tone sliders, then solves Warmth and Tint numerically
    /// through the real filter: a flat patch of the estimate's own color, rendered through the
    /// chain with only Warmth and Tint set, damped Newton on its a* and b* toward the goal.
    /// `CITemperatureAndTint` is a linear map of linear light, so the patch's residual in a*
    /// and b* is the residual for every neutral surface in the frame, whatever its lightness.
    ///
    /// `warmOffset`, when given, is a b* the patch should reach by moving Warmth alone after the
    /// neutral solve, Tint held. The move only ever warms, and it is scaled by the estimator's
    /// fade, so a frame whose cast was left alone as the scene's color gets no offset either.
    /// The Neutralize button passes nil, the wand passes `wandGreyB`. `range` bounds the neutral
    /// solve, `offsetRange` the offset's move (nil means `range`, the wand passes `wandWarmRange`).
    ///
    /// Nil for a frame with no color, or with too few near-grey pixels to read.
    public static func neutralisation(_ developed: DecodedFrame, current: EnhanceSettings,
                                      method p: AdaptiveColour.Parameters = castMethod, warmOffset: Double? = nil,
                                      range: ClosedRange<Double> = wbRange, offsetRange: ClosedRange<Double>? = nil,
                                      render: (DecodedFrame, EnhanceSettings) throws -> DecodedFrame = { try CoreImageEnhance().apply($0, settings: $1) }) rethrows -> Neutralisation? {
        let proxy = sampled(developed, longEdge: 512)
        let seen = try render(proxy, whiteBalanceInput(current))
        guard stats(seen).hasColour else { return nil }
        let r = AdaptiveColour.estimate(seen, parameters: p)
        guard r.support > 0 else { return nil }
        let s = AdaptiveColour.appliedFraction(chroma: r.chroma, amount: 1, parameters: p)
        let goal = AdaptiveColour.target(r, fraction: s, tintShare: p.tintShare)
        let probe = patch(r.l, r.a, r.b)
        func landed(_ w: Double, _ t: Double) throws -> (a: Double, b: Double) {
            var q = EnhanceSettings(); q.warmth = w; q.tint = t
            let m = meanLabD50(try render(probe, q))
            return (m.a, m.b)
        }
        func clampWB(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
        var w = 0.0, t = 0.0
        var c = try landed(w, t)
        if s > 0 {
            for _ in 0..<12 {
                let ea = c.a - goal.a, eb = c.b - goal.b
                if abs(ea) < 0.02 && abs(eb) < 0.02 { break }
                let h = 0.02
                let cw = try landed(w + h, t), ct = try landed(w, t + h)
                // Jacobian of (a*, b*) in (warmth, tint), solved 2 by 2.
                let j11 = (cw.a - c.a) / h, j12 = (ct.a - c.a) / h, j21 = (cw.b - c.b) / h, j22 = (ct.b - c.b) / h
                let det = j11 * j22 - j12 * j21
                guard abs(det) > 1e-9 else { break }
                let w1 = clampWB(w - (j22 * ea - j12 * eb) / det), t1 = clampWB(t - (-j21 * ea + j11 * eb) / det)
                let c1 = try landed(w1, t1)
                // Accept only a step that brings the patch closer, otherwise stop where it is.
                guard hypot(c1.a - goal.a, c1.b - goal.b) < hypot(ea, eb) else { break }
                w = w1; t = t1; c = c1
            }
        }
        var n = Neutralisation(reading: r, fraction: s, goalL: goal.l, goalA: goal.a, goalB: goal.b,
                               neutralWarmth: w, neutralTint: t, neutralA: c.a, neutralB: c.b,
                               warmth: w, tint: t, landedA: c.a, landedB: c.b)
        if let greyB = warmOffset {
            let want = c.b + AdaptiveColour.fade(chroma: r.chroma, parameters: p) * max(0, greyB - c.b)
            var ww = w, cc = c
            for _ in 0..<12 {
                let e = cc.b - want
                if abs(e) < 0.02 { break }
                let h = 0.02
                let slope = (try landed(ww + h, t).b - cc.b) / h
                guard abs(slope) > 1e-9 else { break }
                let w1 = min(max(ww - e / slope, (offsetRange ?? range).lowerBound), (offsetRange ?? range).upperBound)
                let c1 = try landed(w1, t)
                guard abs(c1.b - want) < abs(e) else { break }
                ww = w1; cc = c1
            }
            n.warmth = ww; n.landedA = cc.a; n.landedB = cc.b
        }
        return n
    }

    /// Warmth and Tint that bring the frame's near-grey pixels toward neutral: the Neutralize
    /// button. Nil for a frame with no color or no near-grey pixels.
    public static func neutralising(_ developed: DecodedFrame, current: EnhanceSettings,
                                    render: (DecodedFrame, EnhanceSettings) throws -> DecodedFrame = { try CoreImageEnhance().apply($0, settings: $1) }) rethrows -> (warmth: Double, tint: Double)? {
        guard let n = try neutralisation(developed, current: current, render: render) else { return nil }
        return (n.warmth, n.tint)
    }

    /// A relative near-grey mask: luma 0.2 to 0.8, and within those the lowest quarter by
    /// chroma. Kept as a MEASURE of a frame's cast for the tests.
    public static func neutralMask(_ f: DecodedFrame) -> [Bool] {
        let n = f.width * f.height
        var chroma = [Float](repeating: .infinity, count: n)
        for i in 0..<n {
            let r = Float(f.pixels[i * 3]) / 65535, g = Float(f.pixels[i * 3 + 1]) / 65535, b = Float(f.pixels[i * 3 + 2]) / 65535
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard y >= 0.2, y <= 0.8 else { continue }
            let (_, a, bb) = lab(r, g, b)
            chroma[i] = hypotf(a, bb)
        }
        let finite = chroma.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return [Bool](repeating: false, count: n) }
        let q = finite[finite.count / 4]
        return chroma.map { $0.isFinite && $0 <= q }
    }

    /// Nearest-neighbour down to about `longEdge`, enough for percentiles.
    public static func sampled(_ f: DecodedFrame, longEdge: Int) -> DecodedFrame {
        let step = max(1, max(f.width, f.height) / longEdge)
        guard step > 1 else { return f }
        let w = f.width / step, h = f.height / step
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let s = ((y * step) * f.width + x * step) * 3, d = (y * w + x) * 3
            px[d] = f.pixels[s]; px[d + 1] = f.pixels[s + 1]; px[d + 2] = f.pixels[s + 2]
        } }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// An image file (JPEG, PNG, TIFF) as a 16-bit sRGB frame, scaled to at most `longEdge`.
    /// For the solver and the manifest regression test, which read exported files.
    public static func load(_ url: URL, longEdge: Int = 1024) -> DecodedFrame? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: longEdge,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = img.width, h = img.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { px[i * 3] = raw[i * 4]; px[i * 3 + 1] = raw[i * 4 + 1]; px[i * 3 + 2] = raw[i * 4 + 2] }
        return DecodedFrame(width: w, height: h, pixels: px)
    }
}

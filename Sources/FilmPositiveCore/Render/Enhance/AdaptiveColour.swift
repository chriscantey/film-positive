import Foundation

/// Adaptive Color: how a frame's cast is READ, as a library. Neutralize and the wand call it
/// and write what it reads onto the Warmth and Tint sliders (`AutoEnhance.neutralisation`).
///
/// **It is not a stage.** Nothing a button changes may be hidden, and every change lands on a
/// visible slider. So this only estimates the cast, and the white balance it implies goes onto
/// Warmth and Tint.
///
/// **Everything per frame is measured on that frame.** The cast is estimated from the frame's
/// own pixels by one of the estimator families below. The constants in `Parameters` are METHOD
/// constants (thresholds, strengths, a cap and a fade), one set for every frame. Nothing in the
/// arithmetic knows which frame or which film it is looking at, and a fixed color shift is
/// wrong by construction: two frames of one roll needed casts that differ by an order of
/// magnitude.
///
/// **Working space.** The estimates are made in CIELAB D50 (the Bradford adapted sRGB matrix
/// the assessment scores with) on linear sRGB, because "neutral" is a perceptual quantity and
/// that is the space the objective judges it in. Equal R, G and B is a* = b* = 0 there.
public enum AdaptiveColour {

    /// How the frame's cast is read. Each is an explicit method with a stated assumption.
    public enum Estimator: Int, Sendable, CaseIterable {
        /// Grey world over the pixels that are already nearly grey: midtones (L* inside
        /// `neutralLow` to `neutralHigh`) with chroma under `neutralChroma`. Assumption: a
        /// scene holds some neutral surfaces, and a cast moves them together, so their mean
        /// a* and b* is the cast. Fails when the cast is larger than the threshold (the true
        /// neutrals leave the set) or when a desaturated colored surface dominates the set.
        case lowChroma = 0
        /// The same assumption with a RELATIVE threshold: the lowest `neutralQuantile` of the
        /// midtones by chroma, the wand's `neutralMask`. A strong cast cannot empty the set,
        /// at the price that a frame with no neutrals still hands over its least colored
        /// pixels as if they were grey. The cap and the fade are what protect that frame.
        case lowestQuartile = 1
        /// Grey edge (van de Weijer, Gevers and Gijsenij 2007): the Minkowski mean of each
        /// channel's gradient magnitude, after a small blur. Assumption: the average color of
        /// the DIFFERENCES between neighbouring surfaces is grey. It reads edges rather than
        /// areas, so one large colored area counts once along its border instead of by its
        /// size, which is exactly the failure grey world has on a frame of foliage or sky.
        case greyEdge = 2
        /// White patch in its percentile form: the mean color of the brightest
        /// `brightFraction` of pixels that are not clipped in any channel. Assumption: the
        /// brightest surfaces are white or specular and so carry the light's color. Fails on
        /// a bright colored sky.
        case brightPatch = 3
    }

    /// Every method constant in one place.
    ///
    /// **Where the defaults come from.** A fit against the same three UltraMax frames as
    /// Radiance's (Party, Shasta, Oregon), scoring our render with the correction at amount 1
    /// against reference exports of the same frames on color and tone rows. The frames were
    /// rendered with their own Warmth and Tint set to 0 in memory, so the correction stands in
    /// for a manual white balance: with the sliders left in, every estimator's white balance
    /// fits to nothing, because those sliders already correct the same cast.
    ///
    /// **These are the REDUCED method's constants, chosen for generalization, fitted with the
    /// hard tests held.** The neutral band (L* 25 to 85, C* under 10), the cap (10) and the fade
    /// (30) were held at the values written before the fit, and only five keys were fitted,
    /// with `AdaptiveColourTests`' grey card and color dominant scenes held as penalties. A fit
    /// with the band free scored better on the three frames (242.5 against 256.2 at full size)
    /// and did worse held out (212.7 against 133.0 summed): it narrowed the band to where each
    /// frame's reading happened to suit it. Held out, this set stays within a quarter of its
    /// joint fit on Oregon and Party, and still fails Shasta, which ends worse than no stage.
    /// Three frames of one roll is very few.
    ///
    /// `castStrength` above 1 balances a little past neutral on the blue to yellow axis:
    /// the reference exports render these frames warmer than a grey world balance would, and
    /// the fit follows them only as far as the grey card test allows (a first set at 1.154
    /// with a third of the a* removed failed it: the overshoot in b* dragged the card's a*
    /// away from neutral). Half the green to magenta reading is removed (`tintShare`).
    public struct Parameters: Equatable, Sendable {
        public var estimator: Estimator = .lowChroma
        /// `lowChroma`: C* under which a midtone pixel is a neutral candidate.
        public var neutralChroma: Double = 10
        /// `lowestQuartile`: the fraction of midtone pixels, lowest chroma first.
        public var neutralQuantile: Double = 0.25
        /// The midtone band both grey world estimators read, in L*. Deep shadows carry film
        /// noise and highlights clip, so neither is trusted for a cast.
        public var neutralLow: Double = 25
        public var neutralHigh: Double = 85
        /// `greyEdge`: the Minkowski norm, and the pre-blur radius as a fraction of the long side.
        public var edgeNorm: Double = 2
        public var edgeRadiusFraction: Double = 0.002
        /// `brightPatch`: the brightest fraction of unclipped pixels.
        public var brightFraction: Double = 0.02

        /// The fraction of the estimated cast that is removed, before the cap and the fade.
        public var castStrength: Double = 1.1313
        /// The share of the cast's green to magenta component (a*) removed, relative to its
        /// blue to yellow component (b*). A change of daylight, shade or tungsten moves a scene
        /// mostly along the blue to yellow axis, while green and magenta on a film scan come as
        /// much from the stock, the process and the scan as from the light, so an estimator's
        /// a* reading is the less trustworthy half. 1 treats both halves alike.
        public var tintShare: Double = 0.4966
        /// The most C* the correction may move the estimated neutral. A cast larger than this
        /// is reduced by this much, never removed.
        public var castCap: Double = 10
        /// The estimated cast, in C*, at which the correction has faded to nothing. The fade
        /// starts at half of it. An estimate this large is taken to be the SCENE's color
        /// (a sunset, a lawn) rather than the light's, which is the case every estimator above
        /// gets wrong in the same direction: it would neutralize the subject.
        public var castFade: Double = 30

        public init() {}

        public static let `default` = Parameters()
    }

    // MARK: CIELAB D50 of linear sRGB

    static let m: [Double] = [0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733]
    static let wx = 0.96419, wz = 0.82489
    static let mInv: [Double] = {
        let a = m
        let det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        return [(a[4] * a[8] - a[5] * a[7]) / det, (a[2] * a[7] - a[1] * a[8]) / det, (a[1] * a[5] - a[2] * a[4]) / det,
                (a[5] * a[6] - a[3] * a[8]) / det, (a[0] * a[8] - a[2] * a[6]) / det, (a[2] * a[3] - a[0] * a[5]) / det,
                (a[3] * a[7] - a[4] * a[6]) / det, (a[1] * a[6] - a[0] * a[7]) / det, (a[0] * a[4] - a[1] * a[3]) / det]
    }()

    @inline(__always) static func f(_ t: Double) -> Double {
        let d = 6.0 / 29
        return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29
    }
    @inline(__always) static func fInv(_ t: Double) -> Double {
        let d = 6.0 / 29
        return t > d ? t * t * t : 3 * d * d * (t - 4.0 / 29)
    }

    /// Linear sRGB to CIELAB D50.
    @inline(__always) public static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let x = f((m[0] * r + m[1] * g + m[2] * b) / wx)
        let y = f(m[3] * r + m[4] * g + m[5] * b)
        let z = f((m[6] * r + m[7] * g + m[8] * b) / wz)
        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

    /// CIELAB D50 to linear sRGB.
    @inline(__always) public static func rgb(_ l: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let fy = (l + 16) / 116
        let x = wx * fInv(fy + a / 500), y = fInv(fy), z = wz * fInv(fy - b / 200)
        return (mInv[0] * x + mInv[1] * y + mInv[2] * z, mInv[3] * x + mInv[4] * y + mInv[5] * z,
                mInv[6] * x + mInv[7] * y + mInv[8] * z)
    }

    // MARK: The estimate

    /// What the estimator read off a frame.
    public struct Reading: Equatable, Sendable {
        /// The estimated cast as CIELAB D50 at the estimate's own lightness, and its chroma.
        public var l = 50.0, a = 0.0, b = 0.0
        public var chroma: Double { (a * a + b * b).squareRoot() }
        /// How many pixels the estimate stood on, as a fraction of the samples.
        public var support = 0.0
    }

    /// Samples every `step`th pixel on a grid, enough for means and percentiles.
    static func step(_ w: Int, _ h: Int) -> Int { max(1, Int((Double(w * h) / 400_000).squareRoot().rounded(.down))) }

    /// The cast estimate on an interleaved RGBA linear frame.
    public static func estimate(_ px: UnsafePointer<Float>, rowFloats: Int, width w: Int, height h: Int,
                         parameters p: Parameters) -> Reading {
        var r = Reading()
        let s = step(w, h)
        switch p.estimator {
        case .lowChroma, .lowestQuartile:
            var cand: [(c: Double, l: Double, a: Double, b: Double)] = []
            var total = 0
            for y in stride(from: 0, to: h, by: s) {
                let row = px + y * rowFloats
                for x in stride(from: 0, to: w, by: s) {
                    let (l, a, b) = lab(Double(row[x * 4]), Double(row[x * 4 + 1]), Double(row[x * 4 + 2]))
                    total += 1
                    guard l >= p.neutralLow, l <= p.neutralHigh else { continue }
                    cand.append(((a * a + b * b).squareRoot(), l, a, b))
                }
            }
            var set: ArraySlice<(c: Double, l: Double, a: Double, b: Double)>
            if p.estimator == .lowChroma {
                set = ArraySlice(cand.filter { $0.c < p.neutralChroma })
            } else {
                cand.sort { $0.c < $1.c }
                set = cand.prefix(Int(Double(cand.count) * min(max(p.neutralQuantile, 0), 1)))
            }
            r.support = Double(set.count) / Double(max(total, 1))
            // Half a percent of the frame, the wand neutralizer's own floor: fewer candidates
            // than that is not a reading.
            guard r.support >= 0.005 else { r.support = 0; return r }
            let n = Double(set.count)
            r.l = set.reduce(0) { $0 + $1.l } / n
            r.a = set.reduce(0) { $0 + $1.a } / n
            r.b = set.reduce(0) { $0 + $1.b } / n
        case .greyEdge:
            // Each channel blurred, then |gradient| by central differences on the sample grid,
            // skipping any neighbourhood that touches a clipped pixel.
            let n = w * h
            let rad = max(1, Int((p.edgeRadiusFraction * Double(max(w, h))).rounded()))
            var sums = [0.0, 0.0, 0.0]
            var count = 0
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let blurred = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let tmp = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let clipped = UnsafeMutablePointer<Bool>.allocate(capacity: n)
            defer { plane.deallocate(); blurred.deallocate(); tmp.deallocate(); clipped.deallocate() }
            for y in 0..<h { let row = px + y * rowFloats
                for x in 0..<w { clipped[y * w + x] = max(row[x * 4], row[x * 4 + 1], row[x * 4 + 2]) >= 0.98 } }
            for c in 0..<3 {
                for y in 0..<h { let row = px + y * rowFloats; for x in 0..<w { plane[y * w + x] = row[x * 4 + c] } }
                boxBlur(plane, into: blurred, width: w, height: h, radius: rad, scratch: tmp)
                var acc = 0.0, k = 0
                for y in stride(from: 1, to: h - 1, by: s) { for x in stride(from: 1, to: w - 1, by: s) {
                    let i = y * w + x
                    if clipped[i] || clipped[i - 1] || clipped[i + 1] || clipped[i - w] || clipped[i + w] { continue }
                    let gx = Double(blurred[i + 1] - blurred[i - 1]) / 2, gy = Double(blurred[i + w] - blurred[i - w]) / 2
                    acc += pow((gx * gx + gy * gy).squareRoot(), p.edgeNorm); k += 1
                } }
                sums[c] = pow(acc / Double(max(k, 1)), 1 / p.edgeNorm)
                count = k
            }
            r.support = Double(count) / Double(max(1, ((h - 2) / s + 1) * ((w - 2) / s + 1)))
            guard sums.allSatisfy({ $0 > 0 }) else { r.support = 0; return r }
            castFromRGB(sums, into: &r)
        case .brightPatch:
            var lum: [(y: Double, r: Double, g: Double, b: Double)] = []
            var total = 0
            for y in stride(from: 0, to: h, by: s) {
                let row = px + y * rowFloats
                for x in stride(from: 0, to: w, by: s) {
                    total += 1
                    let R = Double(row[x * 4]), G = Double(row[x * 4 + 1]), B = Double(row[x * 4 + 2])
                    guard max(R, G, B) < 0.98 else { continue }
                    lum.append((m[3] * R + m[4] * G + m[5] * B, R, G, B))
                }
            }
            lum.sort { $0.y > $1.y }
            let top = lum.prefix(max(1, Int(Double(total) * p.brightFraction)))
            r.support = Double(top.count) / Double(max(total, 1))
            guard !top.isEmpty else { r.support = 0; return r }
            let sum = top.reduce(into: [0.0, 0.0, 0.0]) { $0[0] += $1.r; $0[1] += $1.g; $0[2] += $1.b }
            guard sum.allSatisfy({ $0 > 0 }) else { r.support = 0; return r }
            castFromRGB(sum, into: &r)
        }
        return r
    }

    /// An estimate that is a color in linear RGB (only its direction matters), as CIELAB
    /// chromaticity at L* 50, so every estimator reports its cast in the same units.
    static func castFromRGB(_ e: [Double], into r: inout Reading) {
        let y = m[3] * e[0] + m[4] * e[1] + m[5] * e[2]
        let k = 0.1842 / y
        let (l, a, b) = lab(e[0] * k, e[1] * k, e[2] * k)
        r.l = l; r.a = a; r.b = b
    }

    /// The fraction of the estimated cast that is removed: the strength, the fade that hands
    /// a scene-sized estimate back to the scene, and the cap on how far a neutral moves.
    public static func appliedFraction(chroma c: Double, amount: Double, parameters p: Parameters) -> Double {
        guard c > 1e-9 else { return 0 }
        var s = max(amount, 0) * p.castStrength * fade(chroma: c, parameters: p)
        if s * c > p.castCap { s = max(p.castCap, 0) / c }
        return s
    }

    /// The fade alone: 1 for a cast under half of `castFade`, easing to 0 at `castFade`, where
    /// an estimate is taken to be the scene's own color.
    public static func fade(chroma c: Double, parameters p: Parameters) -> Double {
        let e1 = max(p.castFade, 1e-6), e0 = e1 / 2
        let t = min(max((c - e0) / (e1 - e0), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    // MARK: A frame

    /// The cast estimate on a 16-bit sRGB frame, linearised first, which is how Neutralize
    /// and the wand read it.
    public static func estimate(_ f: DecodedFrame, parameters p: Parameters = .default) -> Reading {
        let n = f.width * f.height
        guard n > 0 else { return Reading() }
        var lut = [Float](repeating: 0, count: 65536)
        for i in 0..<65536 {
            let v = Double(i) / 65535
            lut[i] = Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
        }
        var px = [Float](repeating: 1, count: n * 4)
        f.pixels.withUnsafeBufferPointer { s in
            for i in 0..<n { px[i * 4] = lut[Int(s[i * 3])]; px[i * 4 + 1] = lut[Int(s[i * 3 + 1])]; px[i * 4 + 2] = lut[Int(s[i * 3 + 2])] }
        }
        return px.withUnsafeBufferPointer { estimate($0.baseAddress!, rowFloats: f.width * 4, width: f.width, height: f.height, parameters: p) }
    }

    /// The CIELAB D50 color a neutral surface should land on: the estimate less the removed
    /// fraction of its b* and `tintShare` of that fraction of its a*, at the estimate's own L*.
    public static func target(_ r: Reading, fraction s: Double, tintShare: Double) -> (l: Double, a: Double, b: Double) {
        (r.l, r.a * (1 - s * tintShare), r.b * (1 - s))
    }

    // MARK: Box blur

    /// A box mean of side `2r + 1`, separable, O(1) per pixel whatever the radius, with the
    /// frame's edge pixels repeated beyond the border. `src` and `dst` may be the same plane.
    ///
    /// Running sums are kept in Double: at a large radius a Float sum walked across a long row
    /// drifts measurably.
    static func boxBlur(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>,
                        width w: Int, height h: Int, radius r: Int, scratch tmp: UnsafeMutablePointer<Float>) {
        let norm = 1.0 / Double(2 * r + 1)
        // Horizontal, src into tmp, one row per task.
        RadianceOperator.rows(h) { y in
            let s = src + y * w, d = tmp + y * w
            var acc = 0.0
            for k in -r...r { acc += Double(s[min(max(k, 0), w - 1)]) }
            d[0] = Float(acc * norm)
            if w > 1 {
                for x in 1..<w {
                    acc += Double(s[min(x + r, w - 1)]) - Double(s[max(x - r - 1, 0)])
                    d[x] = Float(acc * norm)
                }
            }
        }
        // Vertical, tmp into dst, in bands of columns so each task walks rows contiguously.
        RadianceOperator.bands(w) { x0, x1 in
            let bw = x1 - x0
            guard bw > 0 else { return }
            var acc = [Double](repeating: 0, count: bw)
            acc.withUnsafeMutableBufferPointer { a in
                for kk in -r...r {
                    let row = tmp + min(max(kk, 0), h - 1) * w + x0
                    for c in 0..<bw { a[c] += Double(row[c]) }
                }
                for y in 0..<h {
                    let d = dst + y * w + x0
                    for c in 0..<bw { d[c] = Float(a[c] * norm) }
                    if y + 1 < h {
                        let add = tmp + min(y + r + 1, h - 1) * w + x0
                        let sub = tmp + max(y - r, 0) * w + x0
                        for c in 0..<bw { a[c] += Double(add[c]) - Double(sub[c]) }
                    }
                }
            }
        }
    }
}

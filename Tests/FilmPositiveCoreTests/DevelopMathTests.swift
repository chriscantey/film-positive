import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The develop kernel's own arithmetic, on frames whose base, dye gammas and pixel values
/// this file chose, with every expectation recomputed here from the formula in
/// `DevelopMath`'s comments rather than read from a stored render.
///
/// That is the whole point of the suite. A render captured from an earlier engine can only
/// say that today's output equals yesterday's, which is silent about whether either one is
/// the arithmetic we say we perform. A frame with a known base can say exactly that, and it
/// can say it at the ends, where a real photograph happens to have no samples.
final class DevelopMathTests: XCTestCase {

    /// A synthetic negative with a known base.
    ///
    /// The outer ring is clear film base at `base`, which is what the anchor finds (P99.8
    /// of clip-guarded green, and the base is the brightest thing on a negative). The
    /// interior carries a per-channel ramp, so every channel has a range and the two are
    /// independent.
    private func negative(width w: Int, height h: Int, base: [UInt16], lo: Double, hi: Double) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let border = x < w / 10 || x >= w - w / 10 || y < h / 10 || y >= h - h / 10
                if border {
                    for c in 0..<3 { px[i + c] = base[c] }
                } else {
                    let t = lo + (hi - lo) * Double(x) / Double(max(w - 1, 1))
                    for c in 0..<3 { px[i + c] = UInt16(max(1, (Double(base[c]) * t).rounded())) }
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    // MARK: pass 1

    /// The anchor is the P99.8 of clip-guarded green and the base is that anchor times the
    /// declared ratios, exactly. Both are stated in `DevelopMath`; neither is measured
    /// anywhere else, so a frame whose clear base is a known constant pins them.
    func testTheAnchorIsTheClearBaseAndTheBaseIsTheAnchorTimesTheRatios() {
        let clear: UInt16 = 40_000
        let f = negative(width: 400, height: 300, base: [clear, clear, clear], lo: 0.05, hi: 0.6)
        let anchor = DevelopMath.anchor(f, mono: false)
        XCTAssertEqual(anchor, Int(clear), "the clear border IS the P99.8 of green")

        let ratios = BaseRatios(rg: 0.45, bg: 0.75)
        let base = DevelopMath.base(anchor: anchor, ratios: ratios, mono: false)
        XCTAssertEqual(base[0], Double(anchor) * ratios.rg, accuracy: 1e-12)
        XCTAssertEqual(base[1], Double(anchor), accuracy: 1e-12)
        XCTAssertEqual(base[2], Double(anchor) * ratios.bg, accuracy: 1e-12)

        // mono collapses to one number and cannot carry a cast at all
        let m = DevelopMath.base(anchor: anchor, ratios: ratios, mono: true)
        XCTAssertEqual(m, [Double(anchor), Double(anchor), Double(anchor)])

        // and a blown highlight is not film base: a frame whose brightest pixels are at the
        // clip guard anchors below them, on the clear border instead.
        var withClip = f.pixels
        for i in 0..<(50 * 3) { withClip[i] = 65_535 }
        let clipped = DecodedFrame(width: f.width, height: f.height, pixels: withClip)
        XCTAssertEqual(DevelopMath.anchor(clipped, mono: false), Int(clear))
    }

    /// Density is `log10(base_c) - log10(v_c)` quantised over [dMin, dMax], per channel and
    /// per pixel. Asserted as integer equality against the formula evaluated here, which is
    /// stronger than any tolerance, and then in density units to show the round trip is
    /// inside half a quantisation step (4.3 / 65535, or 3.3e-5).
    func testDensityIsTheLogRatioOfEveryPixelAgainstItsOwnBase() {
        let base = [18_000.0, 40_000.0, 30_000.0]
        let f = negative(width: 220, height: 160,
                         base: [UInt16(base[0]), UInt16(base[1]), UInt16(base[2])], lo: 0.02, hi: 0.9)
        let (q, _, _) = DevelopMath.density(f, base: base, mono: false)
        XCTAssertEqual(q.count, f.pixels.count)

        let halfStep = DevelopConstants.dRange / 65535 / 2
        var worst = 0.0
        var mismatches = 0
        var firstBad = ""
        // Counted rather than asserted per sample: 105,600 XCTAssert calls is minutes of
        // test-runner bookkeeping for one claim.
        for i in stride(from: 0, to: q.count, by: 3) {
            for c in 0..<3 {
                let v = Double(f.pixels[i + c])
                let d = log10(base[c]) - log10(v > 0 ? v : 1)
                let want = min(65535, max(0, qOfD(d)))
                if Int(q[i + c]) != want {
                    mismatches += 1
                    if firstBad.isEmpty { firstBad = "sample \(i / 3) channel \(c): got \(q[i + c]) want \(want)" }
                }
                worst = max(worst, abs(dOfQ(Int(q[i + c])) - d))
            }
        }
        XCTAssertEqual(mismatches, 0, firstBad)
        XCTAssertLessThanOrEqual(worst, halfStep, "the quantised density round trips inside half a step")
        print(String(format: "worst density round trip: %.3e (half a step is %.3e)", worst, halfStep))

        // A pixel sitting exactly on its own base has zero density, in every channel at
        // once, which is the definition the whole pass rests on.
        let atBase = DecodedFrame(width: 1, height: 1, pixels: [UInt16(base[0]), UInt16(base[1]), UInt16(base[2])])
        let (zero, _, _) = DevelopMath.density(atBase, base: base, mono: false)
        for c in 0..<3 { XCTAssertEqual(Int(zero[c]), qOfD(0), "channel \(c) at its own base is zero density") }
    }

    /// The physics ceilings are the green ceiling scaled by each channel's dye gamma, which
    /// is the one place a stock's published numbers reach the render. A gamma of 1 in every
    /// channel leaves all three ceilings on green's.
    func testTheDyeGammasPlaceTheChannelCeilings() {
        let greenHi = qOfD(1.8)
        let gamma = DyeGamma(r: 0.772, g: 1.0, b: 1.047)
        let phys = DevelopMath.physicsRanges(greenHi: greenHi, dyeGamma: gamma)
        let step = DevelopConstants.dRange / 65535

        for (c, g) in [gamma.r, gamma.g, gamma.b].enumerated() {
            XCTAssertEqual(phys[c].lo, qOfD(DevelopConstants.dToe), "channel \(c) floor is the toe")
            XCTAssertEqual(dOfQ(phys[c].hi), dOfQ(greenHi) * g, accuracy: step,
                           "channel \(c) ceiling is the green ceiling times its dye gamma")
        }
        let neutral = DevelopMath.physicsRanges(greenHi: greenHi, dyeGamma: .neutral)
        XCTAssertEqual(Set(neutral.map(\.hi)).count, 1, "neutral gammas put every ceiling on green's")
    }

    // MARK: pass 2

    /// The positive is `clamp((q - lo) * 65535 / (hi - lo))` per channel with no tone step,
    /// so a pixel at the channel floor renders to 0 and one at its ceiling to 65535 whatever
    /// the dye gammas are. Both ends are asserted, because a real photograph has samples in
    /// the middle and the ends are where a scale error hides.
    func testTheRenderIsTheDocumentedRemapAndPinsBothEnds() {
        let gamma = DyeGamma(r: 0.772, g: 1.0, b: 1.047)
        let physics = DevelopMath.physicsRanges(greenHi: qOfD(1.8), dyeGamma: gamma)
        let analysis = FrameAnalysis(anchor: 40_000, base: [18_000, 40_000, 30_000],
                                     percentile: physics, physics: physics,
                                     coarse: Array(repeating: [UInt32](repeating: 0, count: 1024), count: 3),
                                     sampleCount: 1, tone: nil)
        // one pixel per interesting point: below the floor, on it, midway, on the ceiling,
        // above it
        var q: [UInt16] = []
        var points: [[Int]] = []
        for c in 0..<3 {
            let lo = physics[c].lo, hi = physics[c].hi
            points.append([max(0, lo - 500), lo, (lo + hi) / 2, hi, min(65535, hi + 500)])
        }
        for i in 0..<5 { for c in 0..<3 { q.append(UInt16(points[c][i])) } }
        let out = DevelopMath.render(DensityFrame(width: 5, height: 1, q: q), analysis: analysis, flip: false)

        for c in 0..<3 {
            let lo = physics[c].lo, hi = physics[c].hi
            let scale = 65535.0 / Double(hi - lo)
            for i in 0..<5 {
                let want = min(65535, max(0, Int(jsRound(Double(points[c][i] - lo) * scale))))
                XCTAssertEqual(Int(out.pixels[i * 3 + c]), want, "point \(i) channel \(c)")
            }
            XCTAssertEqual(out.pixels[0 * 3 + c], 0, "below the floor clamps to black")
            XCTAssertEqual(out.pixels[1 * 3 + c], 0, "the floor itself is black")
            XCTAssertEqual(out.pixels[3 * 3 + c], 65535, "the channel ceiling is white")
            XCTAssertEqual(out.pixels[4 * 3 + c], 65535, "above the ceiling clamps to white")
        }
    }

    /// End to end on a synthetic negative: the clear base renders to black and the most
    /// exposed pixel to white, which is the inversion the whole kernel exists to perform.
    /// The base is known here, so the expected output is computed rather than remembered.
    func testASyntheticNegativeInvertsToTheExpectedPositive() {
        let clear: [UInt16] = [18_000, 40_000, 30_000]
        let f = negative(width: 300, height: 200, base: clear, lo: 0.02, hi: 0.95)
        let input = DevelopInput(ratios: BaseRatios(rg: Double(clear[0]) / Double(clear[1]),
                                                   bg: Double(clear[2]) / Double(clear[1])),
                                 dyeGamma: .neutral, mono: false, autoTone: false)
        let (analysis, densities) = DevelopMath.analyze(f, input: input)

        // The anchor found the clear border and the base it derived is that border, to the
        // rounding the ratios carry.
        XCTAssertEqual(analysis.anchor, Int(clear[1]))
        for c in 0..<3 { XCTAssertEqual(analysis.base[c], Double(clear[c]), accuracy: 0.5) }

        let out = DevelopMath.render(densities, analysis: analysis, flip: false)
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let i = (y * out.width + x) * 3
            return [Int(out.pixels[i]), Int(out.pixels[i + 1]), Int(out.pixels[i + 2])]
        }

        // The clear border is film base, which is zero density. The floor sits at the toe,
        // 0.05 BELOW film base on purpose, so base renders just above black rather than on
        // it: the expected value is computed from the analysis the run produced.
        //
        // The second assertion is the sanity claim that number has to satisfy, stated from
        // the constants rather than from the measurement: the toe is 0.05 of a density
        // range well over one, so film base belongs in the bottom tenth of the output
        // scale. It came out at 3330 of 65535, which is 5.1 percent.
        let border = pixel(2, 2)
        for c in 0..<3 {
            let lo = analysis.physics[c].lo, hi = analysis.physics[c].hi
            let want = Int(jsRound(Double(qOfD(0) - lo) * 65535.0 / Double(hi - lo)))
            XCTAssertEqual(border[c], want, "clear film base, channel \(c)")
            XCTAssertLessThan(border[c], 6553, "and it sits in the bottom tenth of the scale")
        }

        // The ramp runs from most exposed (densest, so lightest in the positive) on the
        // left to nearest the base (darkest) on the right, and never turns round.
        let mid = out.height / 2
        let left = pixel(out.width / 8, mid), right = pixel(out.width - out.width / 8, mid)
        for c in 0..<3 { XCTAssertGreaterThan(left[c], right[c], "channel \(c) inverts: more density is lighter") }
        var previous = 65536
        for x in stride(from: out.width / 8, to: out.width - out.width / 8, by: 7) {
            let v = pixel(x, mid)[1]
            XCTAssertLessThanOrEqual(v, previous, "the positive never turns round across the ramp")
            previous = v
        }
    }

    /// Mono renders exactly neutral at every pixel, however colored the negative is. The
    /// mono path averages the three channels before it takes a density at all, so a color
    /// cast cannot survive it, and this is the assertion that would catch a channel leaking
    /// through the tables.
    func testMonoIsNeutralAtEveryPixel() {
        let f = negative(width: 200, height: 150, base: [18_000, 40_000, 30_000], lo: 0.03, hi: 0.9)
        let input = DevelopInput(ratios: BaseRatios(rg: 0.45, bg: 0.75), dyeGamma: DyeGamma(r: 0.7, g: 1, b: 1.2),
                                 mono: true, autoTone: true)
        let (analysis, densities) = DevelopMath.analyze(f, input: input)
        let out = DevelopMath.render(densities, analysis: analysis, flip: false)
        var bad = 0
        out.pixels.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count { if p[i] != p[i + 1] || p[i] != p[i + 2] { bad += 1 }; i += 3 }
        }
        XCTAssertEqual(bad, 0, "non-neutral pixels in mono output")
    }
}

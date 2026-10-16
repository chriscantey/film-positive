import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The anchored Auto Tone operator, on synthetic frames.
///
/// What it has to do: hand back a FLAT, editable base image, the same way every time. So
/// the operator may flatten a frame, it must never add contrast, and two frames of a roll
/// must land on the same targets. Every test here is one of those sentences.
///
/// Synthetic frames rather than photographs on purpose: each one is built to make exactly
/// one number move, so a bound can be driven to its edge instead of hunting for a frame
/// that happens to land there.
final class AutoToneTests: XCTestCase {

    // MARK: building frames

    /// A frame whose pixels come from a closure, RGB equal so green is the only channel
    /// that matters and the mono path is not involved.
    private func frame(_ w: Int, _ h: Int, _ value: (Int, Int) -> UInt16) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let v = value(x, y)
                px[(y * w + x) * 3] = v; px[(y * w + x) * 3 + 1] = v; px[(y * w + x) * 3 + 2] = v
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    private var input: DevelopInput {
        DevelopInput(ratios: BaseRatios(rg: 1, bg: 1), dyeGamma: .neutral, mono: false, autoTone: true)
    }

    private var flatInput: DevelopInput {
        DevelopInput(ratios: BaseRatios(rg: 1, bg: 1), dyeGamma: .neutral, mono: false, autoTone: false)
    }

    /// A negative: a bright base with a ramp of darker exposure across it. `base` is the
    /// film base (the clearest thing, so the anchor), `lo` the densest exposed pixel.
    private func ramp(_ w: Int, _ h: Int, base: UInt16, lo: UInt16, hi: UInt16) -> DecodedFrame {
        frame(w, h) { x, y in
            // an outer ring of clear base so the anchor has something to find
            if x < w / 12 || x >= w - w / 12 || y < h / 12 || y >= h - h / 12 { return base }
            let t = Double(x) / Double(max(w - 1, 1))
            return UInt16(Double(lo) + t * Double(hi - lo))
        }
    }

    /// A tone step built straight from declared percentiles, so every bound can be driven
    /// to its edge without hunting for a frame that happens to land there.
    private func step(blackAt: Double, medianAt: Double, span: Int = 40_000) -> ToneStep {
        let physics = ChannelRange(lo: 1_000, hi: 1_000 + span)
        let percentile = ChannelRange(lo: 1_000 + Int(blackAt * Double(span)), hi: physics.hi)
        // one coarse bin carrying every sample, placed so the median lands where asked
        var coarse = [UInt32](repeating: 0, count: 1024)
        let q = physics.lo + Int(medianAt * Double(span))
        coarse[min(1023, max(0, q >> 6))] = 1_000
        return DevelopMath.anchoredAutoTone(coarseGreen: coarse, sampleCount: 1_000,
                                            greenPercentile: percentile, greenPhysics: physics)
    }

    private func percentile(_ f: DecodedFrame, _ p: Double) -> Double {
        var luma: [Double] = []
        luma.reserveCapacity(f.width * f.height)
        for i in stride(from: 0, to: f.pixels.count, by: 3) {
            luma.append((0.2126 * Double(f.pixels[i]) + 0.7152 * Double(f.pixels[i + 1])
                         + 0.0722 * Double(f.pixels[i + 2])) / 65535)
        }
        luma.sort()
        return luma[min(luma.count - 1, max(0, Int(Double(luma.count - 1) * p)))]
    }

    private func developed(_ f: DecodedFrame, _ inp: DevelopInput) -> DecodedFrame {
        let (an, dens) = DevelopMath.analyze(f, input: inp)
        return DevelopMath.render(dens, analysis: an, flip: false, rotate: 0)
    }

    // MARK: (a) the measured black lands on the floor, exactly

    func testMeasuredBlackIsPlacedOnTheFloorExactly() {
        let s = step(blackAt: 0.07, medianAt: 0.40)
        XCTAssertEqual(s.black, 0.07, accuracy: 1e-12)
        XCTAssertEqual(s.placedBlack, DevelopConstants.placedBlack)
        let lut = DevelopMath.toneLUT(s)
        // The measured black is a real number between two code values, and the LUT is
        // sampled at code values, so the assertion is on the code value at or just under
        // it: that one and everything below must come back as the floor exactly.
        let at = Int((0.07 * 65535).rounded(.down))
        XCTAssertEqual(Int(lut[at]), Int(jsRound(DevelopConstants.placedBlack * 65535)))
        // and nothing below it survives: everything darker is clamped onto the same floor
        XCTAssertEqual(lut[0], lut[at])
        XCTAssertEqual(lut[at / 2], lut[at])
        // the frame's own white lands on the ceiling, by the same construction
        XCTAssertEqual(Int(lut[65535]), Int(jsRound(DevelopConstants.placedWhite * 65535)))
    }

    /// The floor and the ceiling are the two numbers picked by eye, so the LUT has to
    /// follow them rather than carrying either one baked in somewhere else.
    func testTheLutFollowsTheDeclaredFloorAndCeiling() {
        var s = step(blackAt: 0.10, medianAt: 0.45)
        s = ToneStep(op: s.op, black: s.black, placedBlack: 0.10, placedWhite: 0.80,
                     gain: s.gain, gainAtCap: s.gainAtCap, median: s.median,
                     exponent: s.exponent, exponentAtBound: s.exponentAtBound)
        let lut = DevelopMath.toneLUT(s)
        XCTAssertEqual(Int(lut[Int((0.10 * 65535).rounded(.down))]), Int(jsRound(0.10 * 65535)))
        XCTAssertEqual(Int(lut[65535]), Int(jsRound(0.80 * 65535)))
    }

    // MARK: (b) the exponent is bounded at both ends and says so

    func testExponentIsClampedAtBothBoundsAndReportsIt() {
        // a very dark frame wants an exponent far below the floor
        let dark = step(blackAt: 0.02, medianAt: 0.05)
        XCTAssertEqual(dark.exponent, DevelopConstants.exponentMin)
        XCTAssertTrue(dark.exponentAtBound, "the low bound fired and nothing said so")

        // a bright frame wants one above 1, which is the direction that ADDS contrast and
        // is exactly what the upper bound exists to refuse
        let bright = step(blackAt: 0.02, medianAt: 0.75)
        XCTAssertEqual(bright.exponent, DevelopConstants.exponentMax)
        XCTAssertTrue(bright.exponentAtBound)
        XCTAssertLessThanOrEqual(bright.exponent, 1.0, "an exponent above 1 steepens the curve")

        // and a frame in the middle is NOT flagged, or the flag means nothing
        let middle = step(blackAt: 0.02, medianAt: 0.40)
        XCTAssertGreaterThan(middle.exponent, DevelopConstants.exponentMin)
        XCTAssertLessThan(middle.exponent, DevelopConstants.exponentMax)
        XCTAssertFalse(middle.exponentAtBound)
        // it hits its target: the stretched median is put on middle gray
        XCTAssertEqual(pow(middle.median, middle.exponent), DevelopConstants.middleGray, accuracy: 0.002)
    }

    // MARK: (c) the gain is capped

    func testGainIsCappedAtTwo() {
        // a frame whose black floats at 0.8 would want a gain of 5
        let high = step(blackAt: 0.80, medianAt: 0.90)
        XCTAssertEqual(high.gain, DevelopConstants.gainCap)
        XCTAssertTrue(high.gainAtCap)

        // at exactly half the range the uncapped gain IS 2, so the cap must not claim it
        let edge = step(blackAt: 0.50, medianAt: 0.70)
        XCTAssertEqual(edge.gain, 2.0, accuracy: 1e-9)
        XCTAssertFalse(edge.gainAtCap)

        // and an ordinary frame is nowhere near it
        let ordinary = step(blackAt: 0.07, medianAt: 0.40)
        XCTAssertEqual(ordinary.gain, 1 / (1 - 0.07), accuracy: 1e-9)
        XCTAssertFalse(ordinary.gainAtCap)
    }

    // MARK: (d) a crop box keeps the outside of the picture out of the tone

    /// Two frames identical INSIDE the box and different outside it, with the same anchor.
    /// With the box the tone step must be identical; without it, different. The second half
    /// is the control: without it this test would pass against an operator that ignored the
    /// pixels entirely.
    func testACropBoxComputesTheToneFromInsideTheBoxOnly() {
        let w = 240, h = 240
        let box = DevelopMath.CropBox(x0: 60, y0: 60, x1: 180, y1: 180)
        let base: UInt16 = 19_500
        func inside(_ x: Int) -> UInt16 {
            let t = Double(x - box.x0) / Double(box.width - 1)
            return UInt16(2_000 + t * 17_000)
        }
        let quiet = frame(w, h) { x, y in
            (x >= box.x0 && x < box.x1 && y >= box.y0 && y < box.y1) ? inside(x) : base
        }
        let noisy = frame(w, h) { x, y in
            if x >= box.x0 && x < box.x1 && y >= box.y0 && y < box.y1 { return inside(x) }
            // outside: half the pixels much darker, which moves the median a long way
            return (x + y) % 2 == 0 ? base : 8_000
        }
        // the anchor is a full-frame measurement and must be unchanged by the outside edit
        XCTAssertEqual(DevelopMath.anchor(quiet, mono: false), DevelopMath.anchor(noisy, mono: false))

        let (a1, _) = DevelopMath.analyze(quiet, input: input, toneBox: box)
        let (a2, _) = DevelopMath.analyze(noisy, input: input, toneBox: box)
        XCTAssertEqual(a1.tone, a2.tone, "pixels outside the crop box moved the tone step")

        let (b1, _) = DevelopMath.analyze(quiet, input: input)
        let (b2, _) = DevelopMath.analyze(noisy, input: input)
        XCTAssertNotEqual(b1.tone, b2.tone, "the control failed: those pixels move nothing, so the test above proves nothing")
    }

    // MARK: (e) the operator never adds contrast

    /// The stated criterion is "it may flatten, it must never add contrast", and this is
    /// where the literal form of it breaks, so the finding is written down rather than the
    /// test bent around it.
    ///
    /// P90 minus P10 measured against the FLAT render is not a property this operator can
    /// guarantee, and the reason is structural rather than a tuning miss. Placing both ends
    /// stretches a frame onto [placedBlack, placedWhite] by construction, and the exponent
    /// lifts hardest around y = g^(1/(1-g)), which is 0.29 at g = 0.65. So a frame whose
    /// shadows sit at the placed black and whose highlights sit above that knee comes out
    /// WIDER, while a frame whose shadows sit well above the black comes out narrower.
    /// Worked at a floor of 0.04 and a ceiling of 0.96, which is where this was found:
    ///
    ///     P10 0.040, P90 0.678  ->  0.638 becomes 0.685   (wider)
    ///     P10 0.200, P90 0.700  ->  0.500 becomes 0.432   (narrower)
    ///
    /// Which direction a frame takes is a property of where its shadows fall AND of the
    /// output span, and both of those move with `placedBlack` and `placedWhite`. Widening
    /// the floor shrinks the span and pushes every frame toward the narrower case, which is
    /// why the shipped pair is 0.20 / 0.92 and not 0.04 / 0.96: on the real roll that took
    /// the frames gaining contrast from 32 of 41 to 3 of 41. The table is on the constants.
    /// What the operator DOES guarantee is asserted here, whatever the pair is.
    func testTheOperatorNeverSteepensAndNeverCrushes() {
        var checked = 0
        for (lo, hi) in [(UInt16(1_000), UInt16(18_000)), (2_000, 9_000), (400, 19_000),
                         (6_000, 19_200), (1_200, 4_000), (300, 2_500)] {
            let f = ramp(160, 120, base: 19_500, lo: lo, hi: hi)
            let (an, _) = DevelopMath.analyze(f, input: input)
            let tone = try! XCTUnwrap(an.tone)

            // 1. it never steepens: the exponent cannot go above 1, which is the whole of
            // the "never add contrast" rule. Exponents as high as 1.937 are what make
            // frames contrasty.
            XCTAssertLessThanOrEqual(tone.exponent, 1.0, "ramp \(lo)...\(hi)")

            // 2. it never crushes: against the same frame put through the same end
            // placement with a LINEAR curve, every output is at or above it. The operator
            // can only open shadows, never close them.
            let curve = DevelopMath.toneLUT(tone)
            let linear = ToneStep(op: tone.op, black: tone.black, placedBlack: tone.placedBlack,
                                  placedWhite: tone.placedWhite, gain: tone.gain, gainAtCap: tone.gainAtCap,
                                  median: tone.median, exponent: 1.0, exponentAtBound: false)
            let straight = DevelopMath.toneLUT(linear)
            for i in stride(from: 0, to: 65536, by: 97) {
                XCTAssertGreaterThanOrEqual(curve[i], straight[i], "ramp \(lo)...\(hi) crushed at \(i)")
            }

            // 3. the ends are where they were declared, on every frame, which is the
            // consistency half of the criterion.
            let out = developed(f, input)
            XCTAssertEqual(percentile(out, 0.005), DevelopConstants.placedBlack, accuracy: 0.02, "ramp \(lo)...\(hi) black")
            XCTAssertEqual(percentile(out, 0.995), DevelopConstants.placedWhite, accuracy: 0.02, "ramp \(lo)...\(hi) white")
            checked += 1
        }
        XCTAssertEqual(checked, 6)
    }

    /// The control for the test above: with the exponent forced ABOVE 1 the curve does
    /// crush, so assertion 2 there is capable of failing. A guard verified only in the
    /// direction it passes is not a guard.
    func testTheCrushCheckCanFail() {
        let tone = step(blackAt: 0.05, medianAt: 0.40)
        let steep = ToneStep(op: tone.op, black: tone.black, placedBlack: tone.placedBlack,
                             placedWhite: tone.placedWhite, gain: tone.gain, gainAtCap: false,
                             median: tone.median, exponent: 1.6, exponentAtBound: false)
        let linear = ToneStep(op: tone.op, black: tone.black, placedBlack: tone.placedBlack,
                              placedWhite: tone.placedWhite, gain: tone.gain, gainAtCap: false,
                              median: tone.median, exponent: 1.0, exponentAtBound: false)
        let a = DevelopMath.toneLUT(steep), b = DevelopMath.toneLUT(linear)
        XCTAssertTrue((0..<65536).contains { a[$0] < b[$0] }, "an exponent of 1.6 must crush and does not")
        // and the operator can never ask for one: the bound refuses it
        XCTAssertEqual(DevelopConstants.exponentMax, 1.0)
    }

    // MARK: (f) two exposures land on the same targets

    /// Consistency is the whole point of the feature. Two ramps two stops apart must come
    /// out with their black, their white and their midtone in the same places.
    func testTwoExposuresLandOnTheSameTargets() {
        let bright = developed(ramp(160, 120, base: 19_500, lo: 2_400, hi: 18_000), input)
        let dark = developed(ramp(160, 120, base: 19_500, lo: 600, hi: 4_500), input)

        for (name, p, tolerance) in [("black", 0.01, 0.02), ("white", 0.99, 0.02)] {
            XCTAssertEqual(percentile(bright, p), percentile(dark, p), accuracy: tolerance,
                           "\(name) is not in the same place on two exposures")
        }
        // the black is not merely CONSISTENT, it is on the declared floor
        XCTAssertEqual(percentile(bright, 0.01), DevelopConstants.placedBlack, accuracy: 0.02)
        XCTAssertEqual(percentile(dark, 0.01), DevelopConstants.placedBlack, accuracy: 0.02)
        XCTAssertEqual(percentile(bright, 0.99), DevelopConstants.placedWhite, accuracy: 0.02)
        XCTAssertEqual(percentile(dark, 0.99), DevelopConstants.placedWhite, accuracy: 0.02)
        // and the midtones are inside one declared band rather than pinned to a point. The
        // band is stated against the constants, not as two numbers that go stale the next
        // time the floor moves.
        for f in [bright, dark] {
            XCTAssertGreaterThan(percentile(f, 0.50), DevelopConstants.placedBlack)
            XCTAssertLessThan(percentile(f, 0.50), DevelopConstants.placedWhite)
        }
    }

    // MARK: the looks interplay: Canvas lifts shadows from a KNOWN floor

    /// Canvas is a LOCAL shadow lift in the enhance layer, so it needs a black that sits in
    /// the same place on every frame. The claim is about the buffer HANDED to the enhance
    /// layer, so that is what is asserted here: develop's output black is the declared floor
    /// whatever the frame was.
    ///
    /// Asserted at develop's boundary rather than through `CIHighlightShadowAdjust`, which
    /// is a GPU filter with its own radius and would measure Core Image rather than this.
    func testTheEnhanceLayerAlwaysStartsFromThePlacedBlack() {
        for (lo, hi) in [(UInt16(1_000), UInt16(18_000)), (500, 5_000), (5_000, 19_000)] {
            let out = developed(ramp(160, 120, base: 19_500, lo: lo, hi: hi), input)
            XCTAssertEqual(percentile(out, 0.005), DevelopConstants.placedBlack, accuracy: 0.02,
                           "ramp \(lo)...\(hi) handed the enhance layer a different floor")
        }
    }

    // MARK: tone off

    /// Tone `.none` changes nothing: the analysis carries no tone step and the render is
    /// the physics remap alone, bit for bit.
    ///
    /// This is the half of the tone contract that is easy to leave untested: the flat render
    /// is the roll-consistent reference every assessment is measured against, so a tone step
    /// that leaked into it would move the baseline rather than the picture.
    func testToneOffLeavesTheNormalisedValuesUntouched() {
        let f = ramp(160, 120, base: 19_500, lo: 1_000, hi: 18_000)
        let (withTone, densities) = DevelopMath.analyze(f, input: input)
        let (withoutTone, _) = DevelopMath.analyze(f, input: flatInput)
        XCTAssertNotNil(withTone.tone)
        XCTAssertNil(withoutTone.tone, "Auto Tone off must produce no tone step at all")

        // Same analysis in every other respect, so the two renders differ only by the LUT.
        XCTAssertEqual(withTone.anchor, withoutTone.anchor)
        XCTAssertEqual(withTone.physics.map(\.lo), withoutTone.physics.map(\.lo))
        XCTAssertEqual(withTone.physics.map(\.hi), withoutTone.physics.map(\.hi))

        // The untoned output IS the physics remap, recomputed here from the documented
        // formula rather than compared against a stored render.
        let out = DevelopMath.render(densities, analysis: withoutTone, flip: false)
        let lo = withoutTone.physics[1].lo, hi = withoutTone.physics[1].hi
        let scale = 65535.0 / Double(hi - lo)
        var checked = 0
        for i in stride(from: 0, to: densities.q.count, by: 3 * 37) {
            let want = min(65535, max(0, Int(jsRound(Double(Int(densities.q[i + 1]) - lo) * scale))))
            XCTAssertEqual(Int(out.pixels[i + 1]), want, "sample \(i / 3)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)

        // And the toned render is different, so the comparison above is not
        // passing because the tone step does nothing.
        let toned = DevelopMath.render(densities, analysis: withTone, flip: false)
        XCTAssertNotEqual(toned.pixels, out.pixels)
    }

    // MARK: the inspector line

    func testTheInspectorLineNamesTheBoundWhenItFires() {
        XCTAssertTrue(step(blackAt: 0.02, medianAt: 0.05).inspectorSummary.contains("at the bound"))
        XCTAssertFalse(step(blackAt: 0.02, medianAt: 0.40).inspectorSummary.contains("at the bound"))
        XCTAssertTrue(step(blackAt: 0.80, medianAt: 0.90).inspectorSummary.contains("at the cap"))
        let ordinary = step(blackAt: 0.07, medianAt: 0.40).inspectorSummary
        let expected = String(format: "black 0.07 -> %.2f, white -> %.2f, exponent ",
                              DevelopConstants.placedBlack, DevelopConstants.placedWhite)
        XCTAssertTrue(ordinary.hasPrefix(expected), "\(ordinary) does not start with \(expected)")
    }
}

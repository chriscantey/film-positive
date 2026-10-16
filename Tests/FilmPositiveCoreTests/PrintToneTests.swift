import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The Print tone operator: the anchored Flat placement followed by a color paper's
/// contrast, applied in density space about the mid-gray pivot with a soft toe and
/// shoulder.
///
/// What it has to do: give the look of a lab print, the punchy contrast a scan from a lab
/// has. So the operator must ADD contrast, which is the exact opposite of Flat's rule, and
/// it must do it without taking anything outside the paper's own density limits.
///
/// Every number it uses but one comes off a manufacturer sheet. The exception is the
/// gamma, which is picked by eye from a sheet of contrast trials, because a print look is a
/// choice and not film data. The first test here holds both halves: the declared value the
/// stage actually applies, and the paper-derived product it was picked against, which is
/// still made of the two published slopes and must still reproduce them.
final class PrintToneTests: XCTestCase {

    private var stage: PrintStage {
        PrintStage.shipped(flatBlack: DevelopConstants.placedBlack,
                           flatWhite: DevelopConstants.placedWhite)
    }

    private func applied(_ v: Double) -> Double { DevelopMath.printTone(v, stage) }

    /// The same operator with the paper exposure turned off, which is the curve the shipped
    /// one is a translation of. Several properties below are properties of the CURVE and
    /// hold here exactly, while the shipped stage slides them by a known amount.
    private func appliedZero(_ v: Double) -> Double {
        DevelopMath.printTone(v, stageWith(exposure: 0))
    }

    // MARK: the derivation

    /// `printGamma` is a declared pick, not film data.
    func testPrintGammaIsADeclaredPick() {
        XCTAssertEqual(DevelopConstants.printGamma, 2.3, accuracy: 1e-12)
    }

    /// The knee width is a density, derived from a 0.2 D margin at each end of the paper's
    /// density range (`paperDensityRange`, Kodak E-4070). In value units it would be two different numbers.
    func testKneeWidthIsADensityDerivedFromTheSheet() {
        let span = log10(DevelopConstants.printWhite) - log10(DevelopConstants.printBlack)
        XCTAssertEqual(DevelopConstants.printKneeWidth,
                       0.2 * span / DevelopConstants.paperDensityRange, accuracy: 1e-12)
        XCTAssertEqual(DevelopConstants.printKneeWidth, 0.13632, accuracy: 0.00001)
        // and the two knees are nowhere near each other, so they can never overlap
        let s = stage
        XCTAssertGreaterThan(s.maxDensity - s.minDensity, 4 * s.kneeWidth)
    }

    // MARK: (a) monotone

    /// A tone operator that is not monotone inverts something somewhere. Checked on the
    /// pure stage over the whole unit interval, and on the composed LUT, which is what
    /// actually renders.
    func testMonotoneOverARamp() {
        var previous = -1.0
        var firstFall: Double?
        for i in 0...200_000 {
            let v = Double(i) / 200_000
            let y = applied(v)
            if y < previous - 1e-12 && firstFall == nil { firstFall = v }
            previous = y
        }
        XCTAssertNil(firstFall, "the stage fell at v = \(firstFall ?? -1)")

        let lut = DevelopMath.printToneLUT(printStep(blackAt: 0.07, medianAt: 0.40))
        var lutFall: Int?
        for i in 1..<65536 where lut[i] < lut[i - 1] { lutFall = i; break }
        XCTAssertNil(lutFall, "the LUT fell at \(lutFall ?? -1)")
    }

    // MARK: (b) the pivot maps to itself

    /// Mid-gray staying put is what makes the paper curve a CONTRAST change rather than an
    /// exposure change, and it is why a Flat render and a Print render of the same frame
    /// can be compared at all. It is a property of the gamma, so it is asserted where the
    /// gamma is the only thing acting: exposure 0.
    func testMidGrayPivotMapsToItselfAtExposureZero() {
        XCTAssertEqual(appliedZero(DevelopConstants.middleGray), DevelopConstants.middleGray,
                       accuracy: 1e-4)
        // tighter than 1e-4, because nothing in the path should cost more than
        // floating point: the pivot is an identity by construction, not by cancellation
        XCTAssertEqual(appliedZero(DevelopConstants.middleGray), DevelopConstants.middleGray,
                       accuracy: 1e-12)
    }

    /// The shipped stage moves the pivot down by exactly the exposure and by nothing else.
    /// That is the claim the constant makes: a pure translation along the density axis,
    /// with neither knee touching it. If a knee ever reached mid-gray this would fail, and
    /// it should, because then the offset would be changing contrast behind the gamma's back.
    func testTheShippedExposureSlidesThePivotByExactlyItselfAndNothingElse() {
        let m = DevelopConstants.middleGray
        XCTAssertEqual(applied(m), m * pow(10, -DevelopConstants.printExposure), accuracy: 1e-12)
        // the same claim read off the constants rather than off a typed number, so the
        // pin can never disagree with the pair it is made of
        XCTAssertEqual(applied(m),
                       DevelopConstants.middleGray
                           * pow(10, -DevelopConstants.printExposure),
                       accuracy: 1e-12)
    }

    // MARK: (c) the slope at the pivot IS the paper gamma

    func testDensitySlopeAtThePivotEqualsPrintGamma() {
        let m = DevelopConstants.middleGray
        let h = 1e-5
        // a symmetric difference in DENSITY, which is the space the gamma is defined in
        let up = -log10(applied(m * pow(10, -h)))
        let down = -log10(applied(m * pow(10, h)))
        let slope = (up - down) / (2 * h)
        XCTAssertEqual(slope, DevelopConstants.printGamma,
                       accuracy: DevelopConstants.printGamma * 0.01)
    }

    // MARK: (d) the knees are C1

    /// Value and first derivative continuous at both junctions. Measured as the largest
    /// step-to-step change in the numerical slope across a window that spans each knee: a
    /// real discontinuity shows up as a jump of order 1, a continuous knee as a jump of
    /// order (step size / knee width).
    func testTheKneesAreC1() {
        let s = stage
        let epsilon = 1e-3
        for (name, centre) in [("shoulder", s.minDensity + s.kneeWidth),
                               ("toe", s.maxDensity - s.kneeWidth)] {
            let jump = largestSlopeJump(around: centre, stage: s)
            XCTAssertLessThan(jump, epsilon, "\(name) is not C1: slope jumped by \(jump)")
        }
    }

    /// The C1 test in the failing direction. A knee narrowed to nothing is a hard clip, and
    /// a hard clip must fail the same detector at the same junction. Without this, a test
    /// that passes proves only that it ran.
    func testTheC1CheckFailsOnAHardClip() {
        let s = stage
        let hard = PrintStage(gamma: s.gamma, pivot: s.pivot, black: s.black, white: s.white,
                              kneeWidth: 1e-9, toeEngaged: true, shoulderEngaged: true)
        for centre in [hard.minDensity, hard.maxDensity] {
            // A hard clip takes the slope from 1 to 0. The sample that straddles the
            // junction reads 0.5, so the largest step-to-step jump the probe can see is
            // exactly 0.5 and the threshold has to sit under it. The shipped knee scores
            // 1e-5 on the same probe, so there are four orders of magnitude between a
            // clip and a knee and nothing delicate about where the line goes.
            XCTAssertGreaterThan(largestSlopeJump(around: centre, stage: hard), 0.4,
                                 "a hard clip passed the C1 check, so the check cannot fail")
        }
    }

    private func largestSlopeJump(around centre: Double, stage s: PrintStage) -> Double {
        let h = 1e-6
        var slopes: [Double] = []
        for i in -400...400 {
            let d = centre + Double(i) * h * 4
            let a = DevelopMath.printKnees(density: d - h, s)
            let b = DevelopMath.printKnees(density: d + h, s)
            slopes.append((b - a) / (2 * h))
        }
        var worst = 0.0
        for i in 1..<slopes.count { worst = max(worst, abs(slopes[i] - slopes[i - 1])) }
        return worst
    }

    // MARK: (e) Print adds contrast

    /// The whole point. On every synthetic ramp, the rendered P90 minus P10 must grow
    /// against the same frame's Flat render.
    func testPrintAddsContrastOnEverySyntheticRamp() {
        var checked = 0
        for base in stride(from: 40_000, through: 60_000, by: 10_000) {
            for lo in [2_000, 6_000, 12_000] {
                for hi in [18_000, 26_000, 34_000] {
                    guard hi > lo, base > hi else { continue }
                    let f = ramp(160, 120, base: UInt16(base), lo: UInt16(lo), hi: UInt16(hi))
                    let (flat, printed) = contrast(f)
                    XCTAssertGreaterThan(printed, flat,
                                         "base \(base) lo \(lo) hi \(hi): C90 \(flat) -> \(printed)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 12, "the sweep covered almost nothing")
    }

    /// And on real frames, which is the claim the synthetic ramps cannot make: a ramp has a
    /// uniform histogram and a photograph does not.
    func testPrintAddsContrastOnTwoRealFixtureFrames() throws {
        let frames = try fixtureFrames(2)
        for (name, f) in frames {
            let (flat, printed) = contrast(f)
            XCTAssertGreaterThan(printed, flat, "\(name): C90 \(flat) -> \(printed)")
        }
    }

    // MARK: (f) nothing leaves the paper's limits

    func testNothingLeavesThePrintLimits() {
        var lowest = 1.0, highest = 0.0
        for i in 0...200_000 {
            let y = applied(Double(i) / 200_000)
            lowest = min(lowest, y); highest = max(highest, y)
        }
        XCTAssertGreaterThanOrEqual(lowest, DevelopConstants.printBlack - 1e-12)
        XCTAssertLessThanOrEqual(highest, DevelopConstants.printWhite + 1e-12)

        // and the rendered LUT, which is where it matters
        let lut = DevelopMath.printToneLUT(printStep(blackAt: 0.07, medianAt: 0.40))
        let floor = UInt16(jsRound(DevelopConstants.printBlack * 65535))
        let ceiling = UInt16(jsRound(DevelopConstants.printWhite * 65535))
        XCTAssertGreaterThanOrEqual(lut.min() ?? 0, floor, "the LUT went below the floor")
        XCTAssertLessThanOrEqual(lut.max() ?? 0, ceiling, "the LUT went above the ceiling")
        // The floor is not a target. The CEILING is one, by choice rather than by
        // regression: at a placement ceiling of 1.0 the frame's own white lands exactly on
        // paper white, 64224 of 65535, which is what "a print may reach paper white"
        // means. At 0.92 it stops at 62770 and no shoulder can raise it.
        //
        // What has to stay true is that the paper gets there through its shoulder and not
        // through a clip, so the band actually sitting on the limit is pinned as well as
        // the endpoint. Measured, not typed: the limit is first reached at input 64382, so
        // 1154 of 65536 entries are on it, 1.8 percent of the range, and the entry below it
        // is exactly one count down. A hard clip would show as a wide band or a jump.
        XCTAssertEqual(Int(lut[65535]), Int(ceiling),
                       "Bold no longer reaches paper white")
        let firstAtCeiling = lut.firstIndex(where: { $0 >= ceiling }) ?? 65536
        XCTAssertEqual(firstAtCeiling, 64382, accuracy: 2,
                       "the band sitting on paper white moved")
        XCTAssertLessThan(65536 - firstAtCeiling, 1_300,
                          "the shoulder is clipping a wide band, not closing on the limit")
        XCTAssertEqual(Int(lut[firstAtCeiling - 1]), Int(ceiling) - 1,
                       "the paper white is arrived at by a jump, not by the knee")
        XCTAssertGreaterThan(lut.min() ?? 0, floor)
        XCTAssertEqual(Int(lut.min() ?? 0), 2218, accuracy: 2,
                       "the black the operator actually reaches moved")

        // and with the offset turned off it is the pre-exposure LUT: the white sits
        // exactly on paper white and the black at 4426. Both numbers are kept so a
        // regression in the gamma or the knees cannot hide behind the exposure default.
        PrintStage.override = PrintStage.Override(exposure: 0)
        let zeroLUT = DevelopMath.printToneLUT(printStep(blackAt: 0.07, medianAt: 0.40))
        PrintStage.override = nil
        XCTAssertEqual(zeroLUT[65535], ceiling, "the pre-exposure white must reach paper white")
        XCTAssertEqual(Int(zeroLUT.min() ?? 0), 4426, accuracy: 2)
        XCTAssertGreaterThanOrEqual(zeroLUT.min() ?? 0, floor)
    }

    /// Nothing clips HARDER than the knee allows: the only inputs that come out exactly on
    /// a limit are the ones whose straight-gamma density is already a full knee width past
    /// it. Anything nearer than that has to come back with detail.
    func testClippingStartsExactlyWhereTheKneeCloses() {
        // the flat value whose straight density sits one knee width above paper white.
        // The exposure is part of the straight density, so it is part of this: leaving it
        // out computes the close point of a curve the operator is no longer running.
        func closePoint(_ s: PrintStage) -> Double {
            let pivotD = -log10(s.pivot)
            let dAtClose = s.minDensity - s.kneeWidth
            return pow(10, -(pivotD + (dAtClose - pivotD - s.exposure) / s.gamma))
        }
        let s = stage
        let vClose = closePoint(s)
        XCTAssertEqual(applied(vClose), s.white, accuracy: 1e-9)
        // one percent below it the operator still has somewhere to go
        XCTAssertLessThan(applied(vClose * 0.99), s.white - 1e-6)

        // And here is what the exposure offset buys, stated as the property rather than as
        // a preference: the flat white target does not reach the close point, so the
        // brightest thing the frame contains comes back with detail instead of on paper
        // white. At exposure 0 it lands inside the clipped region.
        XCTAssertLessThan(DevelopConstants.placedWhite, vClose,
                          "the flat white target is clipping again")
        XCTAssertLessThan(applied(DevelopConstants.placedWhite), s.white - 0.02)
        let zero = stageWith(exposure: 0)
        XCTAssertGreaterThan(DevelopConstants.placedWhite, closePoint(zero))
        XCTAssertEqual(appliedZero(DevelopConstants.placedWhite), zero.white, accuracy: 1e-9)

        // the black end does NOT clip at either exposure: the gamma never carries the flat
        // floor that far
        XCTAssertGreaterThan(applied(DevelopConstants.placedBlack), s.black + 0.01)
        XCTAssertGreaterThan(appliedZero(DevelopConstants.placedBlack), zero.black + 0.01)
    }

    /// Print and Flat share their placement exactly. If they ever stop doing so, the two
    /// modes are no longer a contrast choice and the comparison the inspector invites is a
    /// lie.
    ///
    /// The white is the ONE exception: Print reads `printPlacedWhite`, 1.0 against Flat's
    /// 0.92, because a print may reach paper white. That is the whole of the difference, so
    /// it is asserted from both sides here: the white differs by exactly the two constants,
    /// and every other number the placement produces is still Flat's own.
    func testPrintSharesTheFlatPlacementExceptForTheWhite() {
        let flat = flatStep(blackAt: 0.07, medianAt: 0.40)
        let printed = printStep(blackAt: 0.07, medianAt: 0.40)
        XCTAssertEqual(printed.black, flat.black)
        XCTAssertEqual(printed.placedBlack, flat.placedBlack)
        XCTAssertEqual(flat.placedWhite, DevelopConstants.placedWhite)
        XCTAssertEqual(printed.placedWhite, DevelopConstants.printPlacedWhite)
        XCTAssertGreaterThan(printed.placedWhite, flat.placedWhite,
                             "the print ceiling collapsed back onto Flat's")
        XCTAssertEqual(printed.gain, flat.gain)
        XCTAssertEqual(printed.median, flat.median)
        XCTAssertEqual(printed.exponent, flat.exponent)
        XCTAssertEqual(printed.op, .print)
        XCTAssertNil(flat.printStage)
        XCTAssertNotNil(printed.printStage)
    }

    /// The inspector's one line has to carry the print numbers, or a Print render is
    /// indistinguishable from a Flat one in the only place the app explains itself.
    func testTheInspectorLineCarriesThePrintNumbers() {
        let line = printStep(blackAt: 0.07, medianAt: 0.40).inspectorSummary
        XCTAssertTrue(line.contains(String(format: "print gamma %.2f",
                                           DevelopConstants.printGamma)), line)
        XCTAssertTrue(line.contains("toe at 0.02"), line)
        XCTAssertTrue(line.contains("shoulder at 0.98"), line)
        XCTAssertFalse(flatStep(blackAt: 0.07, medianAt: 0.40).inspectorSummary.contains("print gamma"))
    }

    // MARK: (g) the paper exposure offset, and the sweep override

    /// The shipped value is a pick from a sheet of contrast trials: gamma 2.3 printed
    /// darker by 0.30 D, one choice judged as a pair. Asserted on the constant AND on the
    /// stage the renderer builds, because a constant nothing reads is not a shipped value.
    func testPrintExposureShipsThreeTenthsOfADensity() {
        XCTAssertEqual(DevelopConstants.printExposure, 0.30)
        XCTAssertNil(PrintStage.override, "a previous test left an override set")
        XCTAssertEqual(stage.exposure, DevelopConstants.printExposure, accuracy: 1e-12)
        // and the gamma it was picked with, since neither was chosen on its own
        XCTAssertEqual(stage.gamma, DevelopConstants.printGamma, accuracy: 1e-12)
        // and it reaches the step the renderer builds, not just the constant
        guard let p = printStep(blackAt: 0.07, medianAt: 0.40).printStage else {
            return XCTFail("the shipped step carries no print stage")
        }
        XCTAssertEqual(p.exposure, DevelopConstants.printExposure, accuracy: 1e-12)
        // the shipped render is darker than the pre-exposure one
        let zero = stageWith(exposure: 0)
        XCTAssertLessThan(DevelopMath.printTone(DevelopConstants.middleGray, stage),
                          DevelopMath.printTone(DevelopConstants.middleGray, zero) - 0.01)
    }

    /// Exposure 0 passed explicitly still reproduces the pre-exposure stage, term for term.
    /// That is what makes the offset a knob rather than a rewrite: the pre-exposure curve
    /// is still reachable, so a regression in the gamma or the knees cannot hide behind the
    /// exposure default.
    ///
    /// Bit-identity, not an accuracy: the pre-exposure path is reimplemented here from its
    /// formula and compared with `==`, over a fine ramp and over the whole 65536-entry LUT
    /// that actually renders. An accuracy comparison would pass on a version that quietly
    /// restructured the arithmetic.
    func testExposureZeroPassedExplicitlyIsBitIdenticalToThePreExposureStage() {
        XCTAssertNil(PrintStage.override, "a previous test left an override set")
        let s = stageWith(exposure: 0)
        XCTAssertEqual(s.exposure, 0.0)

        // the pre-exposure expression, written out again rather than called
        func before(_ v: Double) -> Double {
            let pivotD = -log10(s.pivot)
            let dp = pivotD + s.gamma * (-log10(v) - pivotD)
            return pow(10, -DevelopMath.printKnees(density: dp, s))
        }
        for i in 0...50_000 {
            let v = 0.001 + (0.999 - 0.001) * Double(i) / 50_000
            XCTAssertEqual(DevelopMath.printTone(v, s), before(v), "moved at v \(v)")
        }

        // and the composed LUT, which is the thing that renders, built with the offset
        // explicitly turned off rather than with the shipped default
        PrintStage.override = PrintStage.Override(exposure: 0)
        let step = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = nil
        XCTAssertEqual(step.printStage?.exposure, 0.0)
        let lut = DevelopMath.printToneLUT(step)
        let b = step.black, gain = step.gain, g = step.exponent
        let lo = step.placedBlack, span = step.placedWhite - step.placedBlack
        var reference = [UInt16](repeating: 0, count: 65536)
        for i in 0..<65536 {
            var y = (Double(i) / 65535 - b) * gain
            y = y < 0 ? 0 : (y > 1 ? 1 : y)
            reference[i] = UInt16(jsRound(before(lo + span * pow(y, g)) * 65535))
        }
        XCTAssertEqual(lut, reference, "the shipped LUT moved")
    }

    /// The density form and the value form of the straight gamma have to stay the same
    /// function once the offset is in both of them, or the two drift apart the first time
    /// anyone reads one and reasons about the other.
    func testTheValueFormAndTheDensityFormAgreeAtEveryExposure() {
        for e in [-0.30, -0.10, 0.0, 0.10, 0.25, 0.60] {
            let s = stageWith(exposure: e)
            for v in [0.02, 0.10, 0.20, 0.461, 0.70, 0.92, 0.99] {
                XCTAssertEqual(DevelopMath.printStraight(v, s),
                               pow(10, -DevelopMath.printStraightDensity(v, s)),
                               accuracy: 1e-12, "exposure \(e) at v \(v)")
            }
        }
        // and the offset is exactly what it says it is: a density added to the straight
        // gamma, so a value at exposure e is 10^-e times the same value at exposure 0
        let e = DevelopConstants.printExposure
        let zero = stageWith(exposure: 0), lifted = stageWith(exposure: e)
        XCTAssertEqual(DevelopMath.printStraight(0.6, lifted),
                       DevelopMath.printStraight(0.6, zero) * pow(10, -e), accuracy: 1e-12)
        // the pivot maps to itself only at exposure 0; that is the whole difference
        // between this knob and the gamma
        XCTAssertEqual(DevelopMath.printTone(DevelopConstants.middleGray, zero),
                       DevelopConstants.middleGray, accuracy: 1e-9)
        XCTAssertLessThan(DevelopMath.printTone(DevelopConstants.middleGray, lifted),
                          DevelopConstants.middleGray - 0.01)
    }

    /// A positive exposure darkens: every output moves down or stays put, and it stays put
    /// only where a knee has already closed on its limit and there is nowhere left to go.
    func testAPositiveExposureLowersEveryOutputExceptWhereAKneeHasClosed() {
        let zero = stageWith(exposure: 0)
        let darker = stageWith(exposure: DevelopConstants.printExposure)
        var strictlyLower = 0, equalAtALimit = 0, equalAtTheShoulder = 0
        for i in 0...100_000 {
            let v = Double(i) / 100_000
            let a = DevelopMath.printTone(v, zero), b = DevelopMath.printTone(v, darker)
            XCTAssertLessThanOrEqual(b, a + 1e-15, "a positive exposure brightened v \(v)")
            if a <= zero.black + 1e-12 {
                // already on paper black; the offset cannot push it further
                XCTAssertEqual(b, a, accuracy: 1e-12)
                equalAtALimit += 1
            } else if a >= zero.white - 1e-12, b >= darker.white - 1e-12 {
                // Both curves are already on paper white, so the offset has nowhere to
                // push this end either. At the shipped gamma the shoulder closes inside the
                // unit interval at BOTH exposures, which it does not at a shallower one,
                // and the exception is the same exception the black end has.
                // It only covers inputs above the flat white target the placement
                // actually produces: testClippingStartsExactlyWhereTheKneeCloses pins
                // that the target itself still comes back with detail.
                XCTAssertGreaterThan(v, DevelopConstants.placedWhite,
                                     "the shoulder closed on a value the placement emits")
                XCTAssertEqual(b, a, accuracy: 1e-12)
                equalAtTheShoulder += 1
            } else {
                XCTAssertLessThan(b, a, "no darkening at v \(v)")
                strictlyLower += 1
            }
        }
        // The floor is a "did anything move at all" sanity check, not a pin. The shipped
        // steeper gamma parks more of the ramp on the two limits than a shallower one
        // does, so the moving part is smaller: 88760 of 100001 measured here against a
        // shallower curve's 90000-plus. It still has to be the large majority of the ramp.
        XCTAssertGreaterThan(strictlyLower, 85_000, "almost nothing actually moved")
        XCTAssertGreaterThan(strictlyLower, 4 * (equalAtALimit + equalAtTheShoulder),
                             "the limits now own more of the ramp than the curve does")
        XCTAssertGreaterThan(equalAtALimit, 0, "the toe limit was never reached, so the "
                             + "exception this test claims to cover was never exercised")
        XCTAssertGreaterThan(equalAtTheShoulder, 0, "the shoulder limit was never reached, "
                             + "so that exception was never exercised either")
        // the reason to pick it: the shoulder stops clipping as early
        let closes = { (s: PrintStage) -> Double in
            var v = 1.0
            while v > 0.001, DevelopMath.printTone(v, s) >= s.white - 1e-12 { v -= 0.0001 }
            return v
        }
        XCTAssertGreaterThan(closes(darker), closes(zero) + 0.02,
                             "the shoulder did not move up the range")
    }

    /// Monotone is the property the whole operator rests on, and every variant in the
    /// sweep has to hold it, not just the shipped one.
    func testMonotoneUnderEveryVariantInTheSweep() {
        let variants: [(String, PrintStage.Override)] = [
            ("A shipped", PrintStage.Override()),
            ("B exposure +0.15", PrintStage.Override(exposure: 0.15)),
            ("C gamma 1.66 exposure +0.10", PrintStage.Override(gamma: 1.66, exposure: 0.10)),
            ("D exposure +0.15 half knee",
             PrintStage.Override(exposure: 0.15, kneeWidth: DevelopConstants.printKneeWidth / 2)),
            ("E exposure +0.25", PrintStage.Override(exposure: 0.25)),
        ]
        for (name, o) in variants {
            PrintStage.override = o
            defer { PrintStage.override = nil }
            let s = PrintStage.shipped(flatBlack: DevelopConstants.placedBlack,
                                       flatWhite: DevelopConstants.placedWhite)
            var previous = -1.0
            for i in 0...100_000 {
                let y = DevelopMath.printTone(Double(i) / 100_000, s)
                XCTAssertGreaterThanOrEqual(y, previous - 1e-12, "\(name) fell at i \(i)")
                previous = y
            }
            XCTAssertGreaterThanOrEqual(previous, s.black - 1e-12)
            XCTAssertLessThanOrEqual(previous, s.white + 1e-12)
            // and on the LUT that renders, which is where a variant would actually ship
            let lut = DevelopMath.printToneLUT(printStep(blackAt: 0.07, medianAt: 0.40))
            for i in 1..<65536 {
                XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1], "\(name) LUT fell at \(i)")
            }
            XCTAssertGreaterThanOrEqual(lut.min() ?? 0, UInt16(jsRound(s.black * 65535)))
            XCTAssertLessThanOrEqual(lut.max() ?? 0, UInt16(jsRound(s.white * 65535)))
        }
        XCTAssertNil(PrintStage.override, "the sweep leaked an override")
    }

    /// The override has to reach the stage the renderer builds, or a sweep renders five
    /// identical pictures under five different labels, which is worse than not sweeping.
    func testTheOverrideReachesTheRenderedStageAndLeavesNoResidue() {
        let shippedStep = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = PrintStage.Override(gamma: 1.66, exposure: 0.10,
                                                  kneeWidth: 0.07, black: 0.03, white: 0.97)
        let swept = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = nil
        let after = printStep(blackAt: 0.07, medianAt: 0.40)

        guard let p = swept.printStage else { return XCTFail("the swept step carries no stage") }
        XCTAssertEqual(p.gamma, 1.66, accuracy: 1e-12)
        XCTAssertEqual(p.exposure, 0.10, accuracy: 1e-12)
        XCTAssertEqual(p.kneeWidth, 0.07, accuracy: 1e-12)
        XCTAssertEqual(p.black, 0.03, accuracy: 1e-12)
        XCTAssertEqual(p.white, 0.97, accuracy: 1e-12)
        // the placement is untouched by any of it: a sweep changes the paper, never the
        // Flat base Print shares with Flat
        XCTAssertEqual(swept.placedBlack, shippedStep.placedBlack)
        XCTAssertEqual(swept.gain, shippedStep.gain)
        XCTAssertEqual(swept.exponent, shippedStep.exponent)
        // and the LUT really did move, so the override is not decorative
        XCTAssertNotEqual(DevelopMath.printToneLUT(swept), DevelopMath.printToneLUT(shippedStep))
        // clearing it restores the shipped stage exactly
        XCTAssertEqual(after.printStage, shippedStep.printStage)
        XCTAssertEqual(DevelopMath.printToneLUT(after), DevelopMath.printToneLUT(shippedStep))
        // The shipped line names the offset now that the offset is doing something: the
        // rule was never "hide it", it was "only when it is not zero".
        XCTAssertTrue(after.inspectorSummary.contains(
            String(format: "exposure %+.2f D", DevelopConstants.printExposure)),
                      after.inspectorSummary)
        PrintStage.override = PrintStage.Override(exposure: 0)
        let off = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = nil
        XCTAssertFalse(off.inspectorSummary.contains("exposure"),
                       "a line should not mention a knob that is doing nothing")
        XCTAssertTrue(swept.inspectorSummary.contains("exposure +0.10 D"), swept.inspectorSummary)
    }

    // MARK: (h) the print placement ceiling
    //
    // With Flat's `placedWhite`, no print render exceeds 0.92 going into the paper stage
    // and the shoulder cannot raise it: white 1.0 and white 0.98 render identical. Print
    // reads its own constant, 1.0, so a Bold render places its white a full stop above
    // Flat's and the paper shoulder holds the top. Every test below reads the constant
    // rather than repeating its value, so the next pick moves them with it.

    /// A default Print render runs on `printPlacedWhite` and on nothing else, and every
    /// other number in the step is still Flat's. The expected step is written out here
    /// rather than called, and compared with `==` over the whole 65536-entry LUT that
    /// actually renders, so the constant is the only thing that can move a Print render.
    ///
    /// The ceiling is read from the constant, never typed, which is what keeps this test
    /// live through the next pick.
    func testTheDefaultPrintPlacementRunsOnItsOwnConstant() {
        XCTAssertNil(PrintStage.override, "a previous test left an override set")
        XCTAssertGreaterThan(DevelopConstants.printPlacedWhite, DevelopConstants.placedWhite,
                             "Print no longer inherits Flat's ceiling, so this test is live")

        for (blackAt, medianAt) in [(0.07, 0.40), (0.02, 0.22), (0.31, 0.61)] {
            let flat = flatStep(blackAt: blackAt, medianAt: medianAt)
            let printed = printStep(blackAt: blackAt, medianAt: medianAt)
            // everything from Flat except the white, which is Print's own constant, and
            // the stage sized on that same ceiling
            let expected = ToneStep(op: .print, black: flat.black,
                                    placedBlack: flat.placedBlack,
                                    placedWhite: DevelopConstants.printPlacedWhite,
                                    gain: flat.gain, gainAtCap: flat.gainAtCap,
                                    median: flat.median, exponent: flat.exponent,
                                    exponentAtBound: flat.exponentAtBound,
                                    printStage: PrintStage.shipped(
                                        flatBlack: flat.placedBlack,
                                        flatWhite: DevelopConstants.printPlacedWhite))
            XCTAssertEqual(printed, expected, "the step moved at black \(blackAt)")
            XCTAssertEqual(DevelopMath.printToneLUT(printed), DevelopMath.printToneLUT(expected),
                           "the LUT moved at black \(blackAt)")
            XCTAssertEqual(printed.inspectorSummary, expected.inspectorSummary)
            XCTAssertFalse(printed.inspectorSummary.contains("placed white"),
                           "the default names a knob that is doing nothing")
        }
    }

    /// The shipped reading. At Flat's 0.92 the print tops out well short of paper white.
    /// At the shipped constant it clears 0.97 and still stops under the paper's own Dmin,
    /// because the point is that the shoulder has something to work with, not that it
    /// starts clipping.
    ///
    /// Both halves asserted, because "it reaches 0.97" says nothing without the lower
    /// reading. 0.92 is the explicit control here, so it is the one number in the test
    /// written as a literal, and the shipped side reads the constant.
    ///
    /// Measured on the LUT that renders, not on the curve alone.
    func testTheShippedPrintPlacementLiftsTheHighlightsPastNinetySeven() {
        XCTAssertNil(PrintStage.override, "a previous test left an override set")
        func top(_ step: ToneStep) -> Double {
            Double(DevelopMath.printToneLUT(step).max() ?? 0) / 65535
        }

        let shipped = printStep(blackAt: 0.07, medianAt: 0.40)
        XCTAssertEqual(shipped.placedWhite, DevelopConstants.printPlacedWhite)
        let shippedTop = top(shipped)
        XCTAssertGreaterThan(shippedTop, 0.97,
                             "the print no longer reaches paper white: \(shippedTop)")
        XCTAssertLessThanOrEqual(shippedTop, DevelopConstants.printWhite + 1e-9,
                                 "the shoulder stopped holding the paper limit: \(shippedTop)")

        // the control: Flat's 0.92 ceiling
        PrintStage.override = PrintStage.Override(placedWhite: 0.92)
        let control = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = nil

        XCTAssertEqual(control.placedWhite, 0.92)
        let controlTop = top(control)
        XCTAssertLessThan(controlTop, 0.96, "the ceiling research reported is not here")
        XCTAssertGreaterThan(shippedTop, controlTop + 0.02)
        // and it is the placement that moved, not the paper: the stage's own limits and
        // slope are the shipped ones in both renders
        XCTAssertEqual(shipped.printStage?.gamma, DevelopConstants.printGamma)
        XCTAssertEqual(shipped.printStage?.white, DevelopConstants.printWhite)
        XCTAssertEqual(shipped.printStage?.exposure, DevelopConstants.printExposure)
        XCTAssertEqual(control.printStage?.gamma, DevelopConstants.printGamma)
        XCTAssertEqual(control.printStage?.white, DevelopConstants.printWhite)
    }

    /// Flat is not allowed to move. The anchored step reads `placedWhite` and nothing else,
    /// even with a print override standing, which is the whole reason Print got its own
    /// constant instead of the shared one being raised.
    func testTheAnchoredStepIsUnaffectedByThePrintPlacementOverride() {
        let before = flatStep(blackAt: 0.07, medianAt: 0.40)
        // a ceiling that matches neither constant, so a Flat step reading the wrong one
        // cannot pass this by coincidence
        PrintStage.override = PrintStage.Override(placedWhite: 0.99)
        let during = flatStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = nil

        XCTAssertEqual(during.placedWhite, DevelopConstants.placedWhite)
        XCTAssertEqual(during, before)
        XCTAssertEqual(DevelopMath.anchoredToneLUT(during), DevelopMath.anchoredToneLUT(before))
        XCTAssertNil(during.printStage)
        XCTAssertEqual(flatStep(blackAt: 0.07, medianAt: 0.40), before)
    }

    /// The knob reaches the render and leaves nothing behind, same contract as the paper
    /// numbers next to it. The residue half is what stops one sweep variant from bleeding
    /// into the next picture in the strip.
    func testThePlacementOverrideReachesTheStepAndLeavesNoResidue() {
        let shippedStep = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = PrintStage.Override(placedWhite: 0.99)
        let swept = printStep(blackAt: 0.07, medianAt: 0.40)
        PrintStage.override = nil
        let after = printStep(blackAt: 0.07, medianAt: 0.40)

        XCTAssertEqual(swept.placedWhite, 0.99)
        XCTAssertEqual(swept.placedBlack, shippedStep.placedBlack, "the black moved with it")
        XCTAssertEqual(swept.gain, shippedStep.gain)
        XCTAssertEqual(swept.exponent, shippedStep.exponent)
        XCTAssertNotEqual(DevelopMath.printToneLUT(swept), DevelopMath.printToneLUT(shippedStep))
        // the stage is sized against the ceiling that ran, not against the constant
        XCTAssertEqual(swept.printStage,
                       PrintStage.shipped(flatBlack: DevelopConstants.placedBlack, flatWhite: 0.99))
        // the line says so, and only when it is doing something
        XCTAssertTrue(swept.inspectorSummary.contains("placed white 0.99"), swept.inspectorSummary)
        XCTAssertTrue(swept.inspectorSummary.contains("white -> 0.99"), swept.inspectorSummary)
        XCTAssertFalse(shippedStep.inspectorSummary.contains("placed white"))
        // clearing it restores the shipped render exactly
        XCTAssertEqual(after, shippedStep)
        XCTAssertEqual(DevelopMath.printToneLUT(after), DevelopMath.printToneLUT(shippedStep))
        XCTAssertNil(PrintStage.override)
    }

    /// The environment reader: unset means unset, which is the only behavior that keeps a
    /// stray variable from changing a render nobody asked it to change.
    func testTheEnvironmentOverrideIsNilWhenNothingIsSet() {
        XCTAssertNil(PrintStage.Override.fromEnvironment([:]))
        XCTAssertNil(PrintStage.Override.fromEnvironment(["FP_FIXTURES": "/tmp"]))
        guard let o = PrintStage.Override.fromEnvironment(["FP_PRINT_EXPOSURE": "0.15"]) else {
            return XCTFail("a set variable was not read")
        }
        XCTAssertEqual(o.exposure ?? 0, 0.15, accuracy: 1e-12)
        XCTAssertNil(o.gamma, "one variable set must not fill in the other four")
        // a typo is not a request for zero
        XCTAssertNil(PrintStage.Override.fromEnvironment(["FP_PRINT_GAMMA": "one point six"]))
        XCTAssertEqual(PrintStage.Override().summary,
                       PrintStage.Override(gamma: DevelopConstants.printGamma).summary)
        // the placement ceiling is its own variable, and it is not FP_PRINT_WHITE, which
        // is the paper's Dmin: setting one must never fill in the other
        guard let p = PrintStage.Override.fromEnvironment(["FP_PRINT_PLACED_WHITE": "1.0"]) else {
            return XCTFail("FP_PRINT_PLACED_WHITE was not read")
        }
        XCTAssertEqual(p.placedWhite ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertNil(p.white)
        XCTAssertNil(PrintStage.Override.fromEnvironment(["FP_PRINT_WHITE": "0.97"])?.placedWhite)
        XCTAssertTrue(PrintStage.Override().summary.contains(
                          String(format: "placedWhite %.4f", DevelopConstants.printPlacedWhite)),
                      PrintStage.Override().summary)
    }

    private func stageWith(exposure: Double) -> PrintStage {
        let s = stage
        return PrintStage(gamma: s.gamma, pivot: s.pivot, black: s.black, white: s.white,
                          kneeWidth: s.kneeWidth, toeEngaged: s.toeEngaged,
                          shoulderEngaged: s.shoulderEngaged, exposure: exposure)
    }

    // MARK: building things

    private func flatStep(blackAt: Double, medianAt: Double, span: Int = 40_000) -> ToneStep {
        let (coarse, pct, phys) = histogram(blackAt: blackAt, medianAt: medianAt, span: span)
        return DevelopMath.anchoredAutoTone(coarseGreen: coarse, sampleCount: 1_000,
                                            greenPercentile: pct, greenPhysics: phys)
    }

    private func printStep(blackAt: Double, medianAt: Double, span: Int = 40_000) -> ToneStep {
        let (coarse, pct, phys) = histogram(blackAt: blackAt, medianAt: medianAt, span: span)
        return DevelopMath.printAutoTone(coarseGreen: coarse, sampleCount: 1_000,
                                         greenPercentile: pct, greenPhysics: phys)
    }

    private func histogram(blackAt: Double, medianAt: Double, span: Int)
        -> ([UInt32], ChannelRange, ChannelRange) {
        let physics = ChannelRange(lo: 1_000, hi: 1_000 + span)
        let percentile = ChannelRange(lo: 1_000 + Int(blackAt * Double(span)), hi: physics.hi)
        var coarse = [UInt32](repeating: 0, count: 1024)
        coarse[min(1023, max(0, (physics.lo + Int(medianAt * Double(span))) >> 6))] = 1_000
        return (coarse, percentile, physics)
    }

    private func ramp(_ w: Int, _ h: Int, base: UInt16, lo: UInt16, hi: UInt16) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < w / 12 || x >= w - w / 12 || y < h / 12 || y >= h - h / 12
                let t = Double(x) / Double(max(w - 1, 1))
                let v = edge ? base : UInt16(Double(lo) + t * Double(hi - lo))
                let i = (y * w + x) * 3
                px[i] = v; px[i + 1] = v; px[i + 2] = v
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// Luma P90 minus P10 of the same frame rendered Flat and rendered Print.
    private func contrast(_ f: DecodedFrame) -> (flat: Double, print: Double) {
        func c90(_ op: AutoToneOperator) -> Double {
            let input = DevelopInput(ratios: BaseRatios(rg: 1, bg: 1), dyeGamma: .neutral,
                                     mono: false, autoTone: true, autoToneOperator: op)
            let (an, dens) = DevelopMath.analyze(f, input: input)
            let out = DevelopMath.render(dens, analysis: an, flip: false, rotate: 0)
            return percentile(out, 0.90) - percentile(out, 0.10)
        }
        return (c90(.anchored), c90(.print))
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

    /// Real frames from the fixture set, decoded from the RAWS and decimated so the test
    /// stays fast. Both modes see the identical decimated frame, so the comparison is
    /// unaffected by the decimation.
    ///
    /// The raws and not a derived artifact, deliberately. A cheaper derived sibling can be
    /// deleted out from under the test, and then the test does not fail, it SKIPS, which
    /// is the failure direction that hides: a claim about real photographs quietly stops
    /// being made and the suite still reports green.
    private func fixtureFrames(_ count: Int) throws -> [(String, DecodedFrame)] {
        let dir: URL = {
            if let p = ProcessInfo.processInfo.environment["FP_FIXTURES"], !p.isEmpty {
                return URL(fileURLWithPath: p)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("fp-fixtures")
        }()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw XCTSkip("no fixtures at \(dir.path)")
        }
        let raws = names.filter { $0.lowercased().hasSuffix(".cr2") }.sorted().prefix(count)
        if raws.count < count { throw XCTSkip("fewer than \(count) raw fixtures at \(dir.path)") }
        return try raws.map { name in
            let frame = try RawDecoder(halfSize: true).decode(dir.appendingPathComponent(name))
            return (name, Self.decimate(frame, by: 2))
        }
    }

    private static func decimate(_ f: DecodedFrame, by n: Int) -> DecodedFrame {
        let w = f.width / n, h = f.height / n
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let src = ((y * n) * f.width + x * n) * 3
                let dst = (y * w + x) * 3
                px[dst] = f.pixels[src]
                px[dst + 1] = f.pixels[src + 1]
                px[dst + 2] = f.pixels[src + 2]
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }
}

import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The two develop-stage color axes reach the picture, and they reach it through EVERY
/// reader rather than through the one that happened to be edited first.
///
/// `DevelopInput` carries the resolved base pair and the manual axes as separate quantities
/// and exposes `effectiveRatios` as the composition. That split is what lets the inspector
/// still report where the base came from, and it is also a trap: any future call site that
/// reaches for `ratios` out of habit gets a render with the person's grade silently missing,
/// and nothing about it looks wrong.
///
/// So the rule is asserted rather than documented. Each reader is driven with an axis moved
/// and fails if what comes back is unchanged.
final class ColourAxisWiringTests: XCTestCase {

    private let resolved = BaseRatios(rg: 1.08, bg: 0.94)
    private func frame() -> DecodedFrame {
        SceneFixtures.neutralScene(castRG: 1.15, castBG: 0.92)
    }

    private func input(_ axes: ColourAxes, balance: Bool = false) -> DevelopInput {
        DevelopInput(ratios: resolved, dyeGamma: .neutral, mono: false, autoTone: false,
                     colourAxes: axes, balanceChannels: balance)
    }

    /// Mean red over mean green, and mean blue over mean green, of the DEVELOPED frame.
    /// The end of the pipeline rather than a number half way down it, because "did the
    /// grade reach the picture" is a question about the picture.
    private func cast(_ input: DevelopInput) -> (rg: Double, bg: Double) {
        let f = frame()
        let (analysis, density) = DevelopMath.analyze(f, input: input)
        let out = DevelopMath.render(density, analysis: analysis)
        var sum = [0.0, 0.0, 0.0]
        for i in stride(from: 0, to: out.pixels.count, by: 3) {
            for c in 0..<3 { sum[c] += Double(out.pixels[i + c]) }
        }
        return (rg: sum[0] / sum[1], bg: sum[2] / sum[1])
    }

    // MARK: reader 1, the kernel

    /// `analyze` develops through the axes, and the REPORTED BASE DELIBERATELY DOES NOT MOVE.
    ///
    /// Axes folded into the base pair would move the reported base with the grade, and every
    /// histogram taken through it would be a histogram of the graded frame. That lets the
    /// stock's channel balance re-fit and cancel part of the grade.
    ///
    /// The base is the RESOLVED base, always, and the grade reaches the kernel as a
    /// density offset on the rendered value alone. So the base reports where the base came
    /// from, which is what the inspector says it is, and the picture still moves.
    func testTheKernelDevelopsThroughTheAxesWithoutMovingTheReportedBase() {
        let neutral = DevelopMath.analyze(frame(), input: input(.identity))
        let warmed = DevelopMath.analyze(frame(), input: input(ColourAxes(warm: 4)))

        XCTAssertEqual(neutral.0.base, warmed.0.base,
                       "the grade moved the resolved base, which is what re-fitted the balance")
        // And the picture moved anyway, which is the half that proves the axes are wired.
        XCTAssertNotEqual(DevelopMath.render(neutral.1, analysis: neutral.0).pixels,
                          DevelopMath.render(warmed.1, analysis: warmed.0).pixels,
                          "the grade reached nothing")
    }

    // MARK: the direction, which is a claim about the picture and not about the light

    /// Warm up makes the PICTURE warmer. Lab printer values name the color of the light,
    /// where more red light makes a print more cyan, so a sign taken from the printer
    /// convention would invert both labels on the row.
    func testWarmMakesThePictureWarmerAndCoolMakesItCooler() {
        let neutral = cast(input(.identity))
        let warm = cast(input(ColourAxes(warm: 6)))
        let cool = cast(input(ColourAxes(warm: -6)))

        XCTAssertGreaterThan(warm.rg, neutral.rg, "warm did not raise red")
        XCTAssertLessThan(warm.bg, neutral.bg, "warm did not lower blue")
        XCTAssertLessThan(cool.rg, neutral.rg, "cool did not lower red")
        XCTAssertGreaterThan(cool.bg, neutral.bg, "cool did not raise blue")
    }

    /// Magenta up raises red and blue TOGETHER, against green. The other axis moves them in
    /// opposite directions, which is what makes the two independent rather than two names
    /// for one control.
    func testMagentaMovesRedAndBlueTogetherWhereWarmOpposesThem() {
        let neutral = cast(input(.identity))
        let magenta = cast(input(ColourAxes(green: 6)))
        XCTAssertGreaterThan(magenta.rg, neutral.rg)
        XCTAssertGreaterThan(magenta.bg, neutral.bg)

        let warm = cast(input(ColourAxes(warm: 6)))
        XCTAssertGreaterThan(warm.rg, neutral.rg)
        XCTAssertLessThan(warm.bg, neutral.bg)
    }

    // MARK: the unit
    //
    // That one point is 0.025 logE, that the two axes are independent, and that the delta
    // is multiplicative are all properties of the TYPE, and `ColourAxesTests` in the
    // film-sidecar package asserts each of them. What belongs here is the one the KERNEL
    // depends on.

    /// The claim the held green buys, measured rather than argued: moving either axis
    /// leaves the tone step bit-identical.
    func testAColourMoveLeavesTheToneStepBitIdentical() throws {
        let toned = { (axes: ColourAxes) -> ToneStep in
            var i = self.input(axes)
            i.autoTone = true
            return DevelopMath.analyze(self.frame(), input: i).0.tone!
        }
        let neutral = toned(.identity)
        for axes in [ColourAxes(warm: 9), ColourAxes(green: -9), ColourAxes(warm: -5, green: 7)] {
            let moved = toned(axes)
            XCTAssertEqual(moved.black, neutral.black, accuracy: 0, "\(axes) moved the placed black")
            XCTAssertEqual(moved.gain, neutral.gain, accuracy: 0, "\(axes) moved the gain")
            XCTAssertEqual(moved.exponent, neutral.exponent, accuracy: 0, "\(axes) moved the exponent")
        }
    }

    // MARK: anti

    /// The identity is the identity, to the bit. A control that is "off" must leave the
    /// render byte for byte what it was before the control existed, or every frame in the
    /// library changes the day it ships.
    func testTheIdentityRendersExactlyWhatNoAxesRendered() {
        let f = frame()
        var without = input(.identity)
        without.colourAxes = .identity
        let a = DevelopMath.render(DevelopMath.analyze(f, input: without).1,
                                   analysis: DevelopMath.analyze(f, input: without).0)
        var plain = DevelopInput(ratios: resolved, dyeGamma: .neutral, mono: false, autoTone: false)
        plain.balanceChannels = false
        let b = DevelopMath.render(DevelopMath.analyze(f, input: plain).1,
                                   analysis: DevelopMath.analyze(f, input: plain).0)
        XCTAssertEqual(a.pixels, b.pixels, "the identity axes changed the render")
    }

    /// A monochrome frame has no color to grade, and the mono branch of `density` never
    /// reads the offsets at all, so the axes are inert there by construction rather than by
    /// a guard somebody has to remember. Asserted on the rendered density, not on the base,
    /// because the base is now the resolved pair for every input and comparing it would pass
    /// against a build where mono was broken.
    func testTheAxesAreInertOnAMonochromeFrame() {
        let f = frame()
        let plain = DevelopInput(ratios: resolved, dyeGamma: .neutral, mono: true, autoTone: false)
        let graded = DevelopInput(ratios: resolved, dyeGamma: .neutral, mono: true, autoTone: false,
                                  colourAxes: ColourAxes(warm: 12, green: -12))
        XCTAssertEqual(DevelopMath.analyze(f, input: plain).1.q,
                       DevelopMath.analyze(f, input: graded).1.q,
                       "a grade reached a frame with no colour in it")
    }

    /// The grade is a DELTA by construction: the offset is added to the density after the
    /// resolved base has done its work, so it cannot depend on what the base turned out to be.
    ///
    /// A grade set today has to keep meaning the same number of points when the film-edge
    /// reader gets better.
    func testTheGradeAddsTheSameDensityWhateverTheResolvedBaseTurnsOutToBe() {
        let f = frame()
        let axes = ColourAxes(warm: 5, green: -3)
        func delta(_ r: BaseRatios) -> [Int] {
            let plain = DevelopInput(ratios: r, dyeGamma: .neutral, mono: false, autoTone: false)
            var graded = plain
            graded.colourAxes = axes
            let a = DevelopMath.analyze(f, input: plain).1.q
            let b = DevelopMath.analyze(f, input: graded).1.q
            // One unclamped pixel per channel is enough: the per-pixel constancy is asserted
            // over the whole frame in ColourAxisAuthorityTests.
            var out: [Int] = []
            for c in 0..<3 {
                var found = 0
                for i in stride(from: c, to: a.count, by: 3) where a[i] > 0 && a[i] < 65535 && b[i] > 0 && b[i] < 65535 {
                    found = Int(b[i]) - Int(a[i])
                    break
                }
                out.append(found)
            }
            return out
        }
        XCTAssertEqual(delta(BaseRatios(rg: 1.00, bg: 1.00)),
                       delta(BaseRatios(rg: 1.10, bg: 0.90)),
                       "the same grade did a different amount under a different resolved base")
    }
}

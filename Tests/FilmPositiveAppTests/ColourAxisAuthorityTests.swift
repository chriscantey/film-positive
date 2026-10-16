import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// THE ORDERING: the stock's operators run on the FILM, and the manual grade rides after
/// them without being undone by them.
///
/// Two other designs fail, in opposite directions, and this suite keeps either from coming
/// back.
///
/// Folding the axes into the BASE PAIR, upstream of the histograms, lets the channel balance
/// re-fit to the graded frame and cancel part of the grade: 63.3, 64.3 and 100.2 percent
/// retained over three scenes, which is not a constant, so a printer point would mean a
/// different amount on every frame.
///
/// Switching the balance OFF the moment an axis moves fixes the unit and breaks something
/// worse: cinestill-800t's profile declares the balance, measured at about 35 percent
/// contrast over 8 frames, so the first tenth of a point on a slider would silently throw
/// that away. It also puts a step in the control at zero.
///
/// What ships has neither. Nothing switches, nothing re-fits, and the grade is a density
/// offset on the rendered value alone.
final class ColourAxisAuthorityTests: XCTestCase {

    private let resolved = BaseRatios(rg: 1.08, bg: 0.94)

    private func frame() -> DecodedFrame {
        SceneFixtures.neutralScene(castRG: 1.15, castBG: 0.92)
    }

    private func input(_ axes: ColourAxes, balance: Bool) -> DevelopInput {
        DevelopInput(ratios: resolved, dyeGamma: .neutral, mono: false, autoTone: false,
                     colourAxes: axes, balanceChannels: balance)
    }

    // MARK: the stock's operator is never switched off

    /// The balance runs whenever the profile declares it. There is no longer any state in
    /// which moving a slider turns a film profile's own operator off.
    func testTheBalanceRunsWheneverTheStockDeclaresItWhateverTheGradeIs() {
        let f = frame()
        for axes in [ColourAxes.identity, ColourAxes(warm: 0.1), ColourAxes(warm: 9),
                     ColourAxes(green: -7), ColourAxes(warm: -5, green: 6)] {
            let on = DevelopMath.analyze(f, input: input(axes, balance: true)).0
            XCTAssertNotNil(on.balance, "\(axes) switched the stock's balance off")
            let off = DevelopMath.analyze(f, input: input(axes, balance: false)).0
            XCTAssertNil(off.balance, "a stock that declares nothing must still get nothing")
        }
    }

    /// AND IT IS THE SAME BALANCE. This is the "does not undo them" clause as an equality
    /// rather than as a percentage: the operator the stock asked for is fitted to the film,
    /// so the person's grade cannot move it at all.
    ///
    /// A balance that is a function of the grade is what makes the grade partly cancel
    /// itself.
    func testTheMEASUREDBalanceIsIdenticalWhateverTheGrade() throws {
        let f = frame()
        let neutral = try XCTUnwrap(DevelopMath.analyze(f, input: input(.identity, balance: true)).0.balance)
        for axes in [ColourAxes(warm: 12), ColourAxes(green: -12), ColourAxes(warm: -8, green: 8)] {
            let graded = try XCTUnwrap(DevelopMath.analyze(f, input: input(axes, balance: true)).0.balance)
            XCTAssertEqual(graded, neutral, "\(axes) moved the balance the stock asked for")
        }
    }

    // MARK: no step at zero

    /// Moving an axis off zero must not jump the picture, because nothing switches state.
    /// Asserted as continuity: a grade of a thousandth of a point moves almost no pixels, and
    /// a grade of one point moves them by about a point's worth.
    ///
    /// A handoff is the loud failure. With the stretch running at warm 0 and not at warm
    /// 0.0001, the first touch of the slider throws away the whole operator.
    func testMovingAnAxisOffZeroDoesNotStepThePicture() {
        let f = frame()
        func render(_ axes: ColourAxes) -> [UInt16] {
            let (a, d) = DevelopMath.analyze(f, input: input(axes, balance: true))
            return DevelopMath.render(d, analysis: a).pixels
        }
        let rest = render(.identity)
        let nudged = render(ColourAxes(warm: 0.001))
        let onePoint = render(ColourAxes(warm: 1))

        func meanAbsDelta(_ a: [UInt16], _ b: [UInt16]) -> Double {
            var sum = 0.0
            for i in 0..<a.count { sum += abs(Double(a[i]) - Double(b[i])) }
            return sum / Double(a.count)
        }
        let step = meanAbsDelta(rest, nudged)
        let real = meanAbsDelta(rest, onePoint)
        XCTAssertGreaterThan(real, 1, "one point moved nothing, so the comparison below is empty")
        XCTAssertLessThan(step, real / 10,
                          "a thousandth of a point moved the picture by \(step) against \(real) for a "
                          + "whole point, which is a step at zero rather than a continuous control")
    }

    // MARK: the unit, in the domain the unit is defined in

    /// ONE PRINTER POINT IS 0.025 DENSITY, WHICH IS 381.02 q UNITS, ON EVERY FRAME, WITH THE
    /// BALANCE RUNNING.
    ///
    /// This is the assertion the whole naming argument rests on, and it is checked where the
    /// unit actually lives rather than on the final pixel. `q` is linear in density by
    /// construction, so the offset is exact; what could break it is a future change that
    /// makes the offset depend on the frame, which is what folding it into the base did.
    ///
    /// Pixels that clamp at either end of the density domain are excluded, because a clamped
    /// pixel has left the domain the unit is defined in and is the one honest exception.
    func testOnePointMovesTheRenderedDensityByExactlyOnePointOnEveryChannel() {
        let f = frame()
        let expected = ColourAxes.densityPerPoint / DevelopConstants.dRange * 65535
        let rest = DevelopMath.analyze(f, input: input(.identity, balance: true)).1

        for points in [1.0, 4.0, -6.0, 12.0] {
            let graded = DevelopMath.analyze(f, input: input(ColourAxes(warm: points), balance: true)).1
            var checked = 0
            for i in stride(from: 0, to: rest.q.count, by: 3) {
                let r0 = Int(rest.q[i]), r1 = Int(graded.q[i])
                guard r0 > 0, r0 < 65535, r1 > 0, r1 < 65535 else { continue }
                XCTAssertEqual(Double(r1 - r0), points * expected, accuracy: 1.0,
                               "red moved \(r1 - r0) q units for \(points) points")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 1000, "too few unclamped pixels to mean anything")
        }
    }

    /// GREEN IS HELD, to the bit, with the balance running. The tone step and the physics
    /// normalization read the green histogram and nothing else, so this is what makes a
    /// color move leave exposure and contrast exactly where they were.
    func testTheGreenChannelIsBitIdenticalUnderEveryGrade() {
        let f = frame()
        let rest = DevelopMath.analyze(f, input: input(.identity, balance: true)).1
        for axes in [ColourAxes(warm: 12), ColourAxes(green: -12), ColourAxes(warm: -9, green: 9)] {
            let graded = DevelopMath.analyze(f, input: input(axes, balance: true)).1
            for i in stride(from: 1, to: rest.q.count, by: 3) {
                if rest.q[i] != graded.q[i] {
                    XCTFail("green moved at pixel \(i / 3) under \(axes)")
                    return
                }
            }
        }
    }

    // MARK: anti

    /// The identity still renders exactly what a build with no axes rendered, bit for bit,
    /// with the stock's balance running. Every frame already in the library depends on it.
    func testTheIdentityRendersExactlyWhatNoGradeRenders() {
        let f = frame()
        let plain = DevelopInput(ratios: resolved, dyeGamma: .neutral, mono: false,
                                 autoTone: true, balanceChannels: true)
        let withField = input(.identity, balance: true)
        var alsoToned = withField
        alsoToned.autoTone = true

        let a = DevelopMath.analyze(f, input: plain)
        let b = DevelopMath.analyze(f, input: alsoToned)
        XCTAssertEqual(a.0.balance, b.0.balance)
        XCTAssertEqual(DevelopMath.render(a.1, analysis: a.0).pixels,
                       DevelopMath.render(b.1, analysis: b.0).pixels)
    }

    /// cinestill-800t, the stock the whole ordering question was about. Its profile declares
    /// the balance at full strength, and it keeps running with a grade on the frame.
    func testCinestill800tKeepsItsDeclaredBalanceUnderAGrade() throws {
        let profiles = try ProfileLibrary.bundled()
        let d = DevelopSettings(stock: "cinestill-800t",
                                tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        let svc = CPURenderService(profiles: profiles)
        var i = svc.developInput(for: d)
        try XCTSkipUnless(i.balanceChannels, "cinestill-800t no longer declares the balance")
        XCTAssertEqual(i.balanceStrength, 1.0, "the profile's strength moved")

        let f = frame()
        let neutral = try XCTUnwrap(DevelopMath.analyze(f, input: i).0.balance)
        i.colourAxes = ColourAxes(warm: 5)
        let graded = try XCTUnwrap(DevelopMath.analyze(f, input: i).0.balance)
        XCTAssertEqual(graded, neutral, "a grade moved the operator cinestill's profile asked for")
    }

    /// Anti: there is no flag left that could switch a stock's operator off from the grade.
    /// A source scan, with a canary, because the thing to prove is an absence.
    func testNothingRemainsThatCouldSwitchTheStocksOperatorOff() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositiveCore/Render/Develop/DevelopMath.swift")
        let code = ToneNamesTests.strippingComments(try String(contentsOf: source, encoding: .utf8))
        XCTAssertTrue(code.contains("public static func analyze"), "canary: wrong file")
        XCTAssertFalse(code.contains("stretchRuns"), "the stand-down flag is back")
        XCTAssertFalse(code.contains("effectiveRatios"),
                       "the axes are folded into the base again, which is what re-fitted the balance")
    }
}

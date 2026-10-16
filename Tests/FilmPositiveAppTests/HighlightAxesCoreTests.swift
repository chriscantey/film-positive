import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The kernel's highlight axes, a Warm and a Green pair that act on the stock's HIGHLIGHT end,
/// kept for a profile-building tool to drive. No frame's sidecar reaches them
/// (`PlainStockRowTests`). In the kernel they are a density offset on the red and blue physics
/// CEILINGS only, with the Base axes' pattern negated: the floor never moves, so the dark end
/// stays put and the effect grows toward the highlights, and green's ceiling never moves, so
/// the tone step (which reads green alone) cannot see them.
///
/// These run in the app target because that is the target the test filter selects.
final class HighlightAxesCoreTests: XCTestCase {

    private let resolved = BaseRatios(rg: 1.08, bg: 0.94)

    private func frame() -> DecodedFrame {
        SceneFixtures.neutralScene(castRG: 1.15, castBG: 0.92)
    }

    private func input(_ axes: ColourAxes = .identity, mono: Bool = false, autoTone: Bool = false,
                       op: AutoToneOperator = .anchored, balance: Bool = false,
                       gamma: DyeGamma = DyeGamma(r: 0.957, g: 1, b: 1.094)) -> DevelopInput {
        var i = DevelopInput(ratios: resolved, dyeGamma: gamma, mono: mono, autoTone: autoTone,
                             autoToneOperator: op, balanceChannels: balance)
        i.highlightAxes = axes
        return i
    }

    private func tables(_ i: DevelopInput) -> [[UInt16]] {
        let an = DevelopMath.analyze(frame(), input: i).0
        return DevelopTables(analysis: an, mono: i.mono, axisOffsets: i.axisOffsets).tables
    }

    /// The ceiling rule with no highlight axes, written out here so the identity is checked
    /// against an independent copy of the formula rather than against itself.
    private func oldPhysics(greenHi: Int, _ g: DyeGamma) -> [ChannelRange] {
        let gHiD = dOfQ(greenHi)
        let lo = qOfD(DevelopConstants.dToe)
        return [g.r, g.g, g.b].map { ChannelRange(lo: lo, hi: max(qOfD(gHiD * $0), lo + 1)) }
    }

    // MARK: identity

    /// Identity runs today's path, byte for byte, color and mono, with and without a tone
    /// step and a balance.
    func testTheIdentityTablesAreByteIdenticalColourAndMono() {
        for mono in [false, true] {
            for tone in [false, true] {
                for balance in [false, true] {
                    let name = "mono \(mono), tone \(tone), balance \(balance)"
                    let plain = DevelopInput(ratios: resolved, dyeGamma: DyeGamma(r: 0.957, g: 1, b: 1.094),
                                             mono: mono, autoTone: tone, balanceChannels: balance)
                    let explicit = input(ColourAxes(warm: 0, green: -0.0), mono: mono,
                                         autoTone: tone, balance: balance)
                    XCTAssertEqual(tables(plain), tables(explicit), name)
                    let an = DevelopMath.analyze(frame(), input: explicit).0
                    XCTAssertEqual(an.physics,
                                   oldPhysics(greenHi: an.percentile[1].hi,
                                              mono ? .neutral : DyeGamma(r: 0.957, g: 1, b: 1.094)),
                                   "\(name): the ranges are the formula that shipped")
                }
            }
        }
    }

    // MARK: where it acts

    /// Toward Warm, red's ceiling falls and blue's rises by the same density; green's ceiling
    /// and every floor stay exactly where they were. Toward Magenta, red's and blue's fall
    /// together.
    func testWarmAndMagentaMoveOnlyTheRedAndBlueCeilings() {
        let rest = DevelopMath.analyze(frame(), input: input()).0.physics
        let step = Double(qOfD(ColourAxes.densityPerPoint * 8) - qOfD(0))

        let warm = DevelopMath.analyze(frame(), input: input(ColourAxes(warm: 8))).0.physics
        XCTAssertLessThan(warm[0].hi, rest[0].hi, "Warm lowers red's ceiling")
        XCTAssertGreaterThan(warm[2].hi, rest[2].hi, "Warm raises blue's ceiling")
        XCTAssertEqual(Double(rest[0].hi - warm[0].hi), step, accuracy: 1, "by 8 points of density")
        XCTAssertEqual(Double(warm[2].hi - rest[2].hi), step, accuracy: 1, "by 8 points of density")

        let magenta = DevelopMath.analyze(frame(), input: input(ColourAxes(green: 8))).0.physics
        XCTAssertLessThan(magenta[0].hi, rest[0].hi, "Magenta lowers red's ceiling")
        XCTAssertLessThan(magenta[2].hi, rest[2].hi, "Magenta lowers blue's ceiling")

        for (name, moved) in [("warm", warm), ("magenta", magenta)] {
            XCTAssertEqual(moved[1], rest[1], "\(name) moved green's range")
            XCTAssertEqual(moved.map(\.lo), rest.map(\.lo), "\(name) moved a floor")
        }
    }

    /// On the rendered picture: 8 points toward Warm moves the bright fifth's red against blue
    /// clearly and the dark fifth's barely. The same for Magenta, G against R and B.
    ///
    /// Measured as a DIFFERENCE of code values, not a ratio, and that is the honest metric
    /// rather than a convenient one. The remapped value is affine in density, so a moved
    /// ceiling is a gain about the floor: it multiplies every value of that channel by the
    /// same factor, which moves the RATIO of two channels by the same factor at both ends.
    /// What grows toward the highlights is the size of the move, `v * (k - 1)`, zero at the
    /// floor and largest at white, and a difference of code values is what sees that.
    func testTheEffectGrowsTowardTheHighlights() {
        // A ramp over about two densities, a real negative's range, rather than the shared
        // fixture's 0.7: on a short ramp the "dark" fifth is half way up the scale.
        let w = 400, h = 20
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let v = pow(10, -2 * Double(x) / Double(w - 1)) * 0.9 * 65535
                let i = (y * w + x) * 3
                px[i] = UInt16(v * 1.08); px[i + 1] = UInt16(v); px[i + 2] = UInt16(v * 0.94)
            }
        }
        let ramp = DecodedFrame(width: w, height: h, pixels: px)
        func fifths(_ axes: ColourAxes) -> (bright: [Double], dark: [Double]) {
            let i = input(axes)
            let (an, _) = DevelopMath.analyze(ramp, input: i)
            let out = DevelopTables(analysis: an, mono: false, axisOffsets: i.axisOffsets)
                .apply(ramp, flip: false)
            var px: [(Double, Double, Double)] = []
            for p in stride(from: 0, to: out.pixels.count, by: 3) {
                px.append((Double(out.pixels[p]), Double(out.pixels[p + 1]), Double(out.pixels[p + 2])))
            }
            px.sort { $0.1 < $1.1 }
            let n = px.count / 5
            func mean(_ s: ArraySlice<(Double, Double, Double)>) -> [Double] {
                let c = Double(s.count)
                return [s.map(\.0).reduce(0, +) / c, s.map(\.1).reduce(0, +) / c, s.map(\.2).reduce(0, +) / c]
            }
            return (mean(px[(px.count - n)...]), mean(px[..<n]))
        }
        let rest = fifths(.identity)
        let warm = fifths(ColourAxes(warm: 8))
        // Red minus blue, in 16-bit code values: positive is warmer.
        let rb = { (m: [Double]) in m[0] - m[2] }
        let brightWarm = rb(warm.bright) - rb(rest.bright)
        let darkWarm = rb(warm.dark) - rb(rest.dark)
        XCTAssertGreaterThan(brightWarm, 0.05 * 65535, "the bright fifth warms clearly")
        XCTAssertLessThan(abs(darkWarm), brightWarm / 3, "the dark fifth barely moves")
        XCTAssertGreaterThanOrEqual(darkWarm, 0, "and what little it moves is the same way")

        // The mean of red and blue minus green: positive is more magenta.
        let magenta = fifths(ColourAxes(green: 8))
        let mg = { (m: [Double]) in (m[0] + m[2]) / 2 - m[1] }
        let brightMagenta = mg(magenta.bright) - mg(rest.bright)
        let darkMagenta = mg(magenta.dark) - mg(rest.dark)
        XCTAssertGreaterThan(brightMagenta, 0.03 * 65535, "the bright fifth goes magenta")
        XCTAssertLessThan(abs(darkMagenta), brightMagenta / 3, "the dark fifth barely moves")
        XCTAssertEqual(magenta.bright[1], rest.bright[1], "green's own values do not move")
        print(String(format: "ramp: warm 8 moves R-B by %.0f bright, %.0f dark; magenta 8 moves (R+B)/2-G by %.0f bright, %.0f dark",
                     brightWarm, darkWarm, brightMagenta, darkMagenta))
    }

    // MARK: what it must not touch

    /// The tone step's measured numbers, and the stock's balance, are the same under every
    /// axis value, for both tone operators.
    func testTheToneStepAndTheBalanceAreUnchangedByAnyAxisValue() {
        for op in [AutoToneOperator.anchored, .print] {
            for balance in [false, true] {
                let rest = DevelopMath.analyze(frame(), input: input(autoTone: true, op: op, balance: balance)).0
                XCTAssertNotNil(rest.tone)
                for axes in [ColourAxes(warm: 8), ColourAxes(green: -8), ColourAxes(warm: -12, green: 12),
                             ColourAxes(warm: 200), ColourAxes(green: -200)] {
                    let an = DevelopMath.analyze(frame(), input: input(axes, autoTone: true, op: op,
                                                                       balance: balance)).0
                    XCTAssertEqual(an.tone, rest.tone, "\(axes) moved the \(op) tone step")
                    XCTAssertEqual(an.balance, rest.balance, "\(axes) moved the stock's balance")
                }
            }
        }
    }

    /// Mono ignores the axes, as it ignores the Base ones: its table reads channel 0's range.
    func testMonoIgnoresTheAxes() {
        let rest = tables(input(mono: true))
        for axes in [ColourAxes(warm: 8), ColourAxes(green: -8), ColourAxes(warm: 200, green: 200)] {
            XCTAssertEqual(tables(input(axes, mono: true)), rest, "\(axes) moved a mono frame")
        }
    }

    // MARK: the clamp

    /// A ceiling can never fall to or below the floor, however far a typed value pulls it.
    func testACeilingNeverFallsToTheFloor() {
        let lo = qOfD(DevelopConstants.dToe)
        let direct = DevelopMath.physicsRanges(greenHi: qOfD(1.2), dyeGamma: .neutral,
                                               ceilingOffsets: [-10, 0, -10])
        XCTAssertEqual(direct[0], ChannelRange(lo: lo, hi: lo + 1))
        XCTAssertEqual(direct[2], ChannelRange(lo: lo, hi: lo + 1))
        XCTAssertEqual(direct[1], DevelopMath.physicsRanges(greenHi: qOfD(1.2), dyeGamma: .neutral)[1])

        // Through the slider's own storage limit, both ways on warm and magenta.
        for axes in [ColourAxes(warm: 200), ColourAxes(warm: -200), ColourAxes(green: 200)] {
            let i = input(axes)
            let an = DevelopMath.analyze(frame(), input: i).0
            for c in [0, 2] {
                XCTAssertGreaterThan(an.physics[c].hi, an.physics[c].lo, "\(axes) channel \(c)")
            }
            // And the table still builds, with no division by zero reaching a pixel.
            let t = DevelopTables(analysis: an, mono: false, axisOffsets: i.axisOffsets).tables
            XCTAssertEqual(t.count, 3)
        }
        let pulled = DevelopMath.analyze(frame(), input: input(ColourAxes(warm: 200))).0.physics
        XCTAssertEqual(pulled[0].hi, lo + 1, "Warm 200 pulls red's ceiling to the clamp")
    }

    /// Green's ceiling never moves, whatever a caller sets.
    func testGreensCeilingOffsetIsAlwaysZero() {
        for axes in [ColourAxes(warm: 3, green: -2), ColourAxes(warm: -8, green: 5), .identity] {
            XCTAssertEqual(input(axes).ceilingOffsets[1], 0, "\(axes)")
        }
    }
}

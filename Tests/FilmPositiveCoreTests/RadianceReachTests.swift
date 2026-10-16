import XCTest
import CoreImage
import FilmSidecar
@testable import FilmPositiveCore

/// Radiance past 1: for 1 < |v| <= 2 the measured operator runs twice, at full strength on v's
/// side and then at the remainder on that output, and past 2 the amount holds at 2. These are
/// the pair's own properties: the composition is exact, the clamp, continuity at 1, flat
/// fields, direction along the outer halves, finite output, and the kernel path.
final class RadianceReachTests: XCTestCase {
    typealias Op = RadianceOperator
    typealias T = RadianceOperatorTests

    static let outerTenths = (11...20).map { Double($0) / 10 }

    /// L* of every pixel of a linear RGBA frame.
    static func lstars(_ px: [Float]) -> [Double] {
        (0..<(px.count / 4)).map { T.lstar(Double(px[$0 * 4]), Double(px[$0 * 4 + 1]), Double(px[$0 * 4 + 2])) }
    }

    /// The output L* of a flat grey field of sRGB input level `n` of 255.
    static func flatL(_ n: Int, _ v: Double) -> Double {
        let c = Float(T.decode(Double(n) / 255))
        let out = Op.apply(T.linearFrame(4, 4) { _, _ in (c, c, c) }, width: 4, height: 4, amount: v)
        let o = (2 * 4 + 2) * 4
        return T.lstar(Double(out[o]), Double(out[o + 1]), Double(out[o + 2]))
    }

    // MARK: The rule

    /// The passes an amount runs as, at the edges of each range.
    func testThePassesOfAnAmount() {
        XCTAssertEqual(Op.passes(0.4), [0.4])
        XCTAssertEqual(Op.passes(1), [1])
        XCTAssertEqual(Op.passes(-1), [-1])
        XCTAssertEqual(Op.passes(1.5), [1, 0.5])
        XCTAssertEqual(Op.passes(-1.5), [-1, -0.5])
        XCTAssertEqual(Op.passes(2), [1, 1])
        XCTAssertEqual(Op.passes(-2), [-1, -1])
        XCTAssertEqual(Op.passes(2.3), [1, 1])
        XCTAssertEqual(Op.passes(-5), [-1, -1])
    }

    /// Radiance 1.5 is Radiance 0.5 applied to the output of Radiance 1.0, bit for bit, and
    /// the same on the left, on a noise image and on a frame above the proxy size. Fails if the
    /// second pass reuses the first pass's base or the remainder is taken from the wrong side.
    func testPastOneIsTheOperatorAppliedTwice() {
        let (nw, nh, noise) = T.noise
        let frames = [(nw, nh, noise), (700, 420, T.scene(700, 420))]
        for (w, h, px) in frames {
            for side in [1.0, -1.0] {
                let direct = Op.apply(px, width: w, height: h, amount: 1.5 * side)
                let first = Op.apply(px, width: w, height: h, amount: side)
                let twice = Op.apply(first, width: w, height: h, amount: 0.5 * side)
                XCTAssertEqual(direct.map(\.bitPattern), twice.map(\.bitPattern), "\(w)x\(h) at \(1.5 * side)")
            }
        }
    }

    /// An amount of 2.3 renders as 2 and -5 as -2, bit for bit.
    func testTheAmountHoldsAtTwo() {
        let (w, h, px) = T.noise
        let at2 = Op.apply(px, width: w, height: h, amount: 2)
        let atm2 = Op.apply(px, width: w, height: h, amount: -2)
        XCTAssertEqual(Op.apply(px, width: w, height: h, amount: 2.3).map(\.bitPattern), at2.map(\.bitPattern))
        XCTAssertEqual(Op.apply(px, width: w, height: h, amount: -5).map(\.bitPattern), atm2.map(\.bitPattern))
        XCTAssertNotEqual(at2.map(\.bitPattern), Op.apply(px, width: w, height: h, amount: 1).map(\.bitPattern),
                          "2 renders as 1: the amount is still clamped at 1")
    }

    /// Just past 1 lands within 0.05 L* of 1 on every pixel of a noise image, both sides.
    /// Fails if the second pass does not start from the identity.
    func testContinuousAtOne() {
        let (w, h, px) = T.noise
        for side in [1.0, -1.0] {
            let a = Self.lstars(Op.apply(px, width: w, height: h, amount: side))
            let b = Self.lstars(Op.apply(px, width: w, height: h, amount: 1.001 * side))
            let worst = zip(a, b).map { abs($0 - $1) }.max()!
            print(String(format: "RADIANCE reach continuity at %+.0f: max %.4f L*", side, worst))
            XCTAssertLessThanOrEqual(worst, 0.05, "at \(side) the step to \(1.001 * side) is \(worst) L*")
        }
    }

    // MARK: Flat fields

    /// sRGB 0 to 255 at every 0.1 of |v| from 1.1 to 2.0, both sides: every step up the input
    /// is a step up the output, black stays black and white stays white.
    func testFlatFieldsPastOneNeverStepBackwards() {
        var minStep = Double.infinity, at = (0.0, 0)
        for m in Self.outerTenths { for v in [m, -m] {
            let ys = (0...255).map { T.flat($0, v) * 255 }
            XCTAssertEqual(ys[0], 0, "v \(v): black")
            XCTAssertEqual(ys[255], 255, accuracy: 1e-3, "v \(v): white")
            for i in 1...255 where ys[i] - ys[i - 1] < minStep { minStep = ys[i] - ys[i - 1]; at = (v, i) }
        } }
        print(String(format: "RADIANCE reach flat fields: min step %.4f levels at v %+.1f, input %d", minStep, at.0, at.1))
        XCTAssertGreaterThan(minStep, 0, "a flat field step that does not rise, at v \(at.0) input \(at.1)")
    }

    /// As |v| goes from 1.0 to 2.0 in tenths, each flat input's output L* moves one way: no
    /// step against its net direction of more than 0.1 L*, both sides.
    func testEachFlatInputMovesOneWayPastOne() {
        for side in [1.0, -1.0] {
            let seq = (10...20).map { k in (0...255).map { Self.flatL($0, side * Double(k) / 10) } }
            var worst = 0.0, at = 0
            for j in 0...255 {
                let net = seq[10][j] - seq[0][j]
                let dir: Double = net > 0 ? 1 : net < 0 ? -1 : 0
                for k in 0..<10 {
                    let against = -(seq[k + 1][j] - seq[k][j]) * dir
                    if against > worst { worst = against; at = j }
                }
            }
            print(String(format: "RADIANCE reach one direction, side %+.0f: worst step against %.4f L* at input %d", side, worst, at))
            XCTAssertLessThanOrEqual(worst, 0.1, "side \(side): input \(at) steps \(worst) L* against its direction")
        }
    }

    // MARK: Extended values

    /// Channels from -0.1 to 4.0 in every combination, at 2 and -2: every output is finite and
    /// no channel changes sign.
    func testExtendedInputsStayFiniteAndKeepTheirSign() {
        let vals: [Float] = [-0.1, -0.01, 0, 0.001, 0.01, 0.1, 0.5, 1, 1.5, 2, 4]
        let n = vals.count
        let px = T.linearFrame(n * n, n) { x, y in (vals[x / n], vals[x % n], vals[y]) }
        for v in [2.0, -2.0] {
            let out = Op.apply(px, width: n * n, height: n, amount: v)
            var bad = 0, flipped = 0
            for i in 0..<(n * n * n) { for c in 0..<3 {
                let a = px[i * 4 + c], b = out[i * 4 + c]
                if !b.isFinite { bad += 1 }
                if a * b < 0 { flipped += 1 }
            } }
            XCTAssertEqual(bad, 0, "v \(v): \(bad) non-finite channels")
            XCTAssertEqual(flipped, 0, "v \(v): \(flipped) channels changed sign")
        }
    }

    // MARK: The kernel path

    /// The chain with Radiance alone at 1.5 and -1.5 renders what the pure function computes on
    /// the same pixels, within 0.02 L*, under and above the proxy size. Fails if anything on
    /// the way to the kernel holds the amount at 1.
    func testThePureFunctionEqualsTheChainPastOne() throws {
        for (w, h) in [(320, 240), (700, 420)] {
            let lin = T.scene(w, h)
            var px = [UInt16](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { for c in 0..<3 {
                px[i * 3 + c] = UInt16((T.encode(Double(lin[i * 4 + c])) * 65535).rounded())
            } }
            let frame = DecodedFrame(width: w, height: h, pixels: px)
            var decoded = [Float](repeating: 1, count: w * h * 4)
            for i in 0..<(w * h) { for c in 0..<3 { decoded[i * 4 + c] = Float(T.decode(Double(px[i * 3 + c]) / 65535)) } }
            for v in [1.5, -1.5] {
                var s = EnhanceSettings.identity
                s.radiance = v
                let chain = try CoreImageEnhance().apply(frame, settings: s)
                let pure = Op.apply(decoded, width: w, height: h, amount: v)
                var worst = 0.0
                for i in 0..<(w * h) {
                    let a = T.lstar(T.decode(Double(chain.pixels[i * 3]) / 65535), T.decode(Double(chain.pixels[i * 3 + 1]) / 65535),
                                    T.decode(Double(chain.pixels[i * 3 + 2]) / 65535))
                    let b = T.lstar(T.decode(T.encode(Double(pure[i * 4]))), T.decode(T.encode(Double(pure[i * 4 + 1]))),
                                    T.decode(T.encode(Double(pure[i * 4 + 2]))))
                    worst = max(worst, abs(a - b))
                }
                print(String(format: "RADIANCE reach chain against pure, %dx%d v %+.1f: max %.4f L*", w, h, v, worst))
                XCTAssertLessThanOrEqual(worst, 0.02, "\(w)x\(h) at \(v): chain and pure differ by \(worst) L*")
            }
        }
    }
}

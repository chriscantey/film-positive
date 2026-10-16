import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Black Point is a levels remap: `out = (in - b) / (1 - b)` going up and
/// `out = lift + in * (1 - lift)` coming down. A curve that pins the three upper control
/// points clips a toe and cannot restretch anything, and its spline overshoots on the way
/// back to the pins.
///
/// The ramp is the instrument. Every assertion below is over a 256 step grey ramp read
/// back through the real stage, so it measures the shipping chain rather than the
/// arithmetic that was meant to drive it.
final class EnhanceBlackPointTests: XCTestCase {
    static let steps = 256
    static let base: DecodedFrame = {
        var px = [UInt16](repeating: 0, count: steps * 8 * 3)
        for y in 0..<8 {
            for x in 0..<steps {
                let c = UInt16(x * 257)
                let o = (y * steps + x) * 3
                px[o] = c; px[o + 1] = c; px[o + 2] = c
            }
        }
        return DecodedFrame(width: steps, height: 8, pixels: px)
    }()

    let stage = CoreImageEnhance()

    /// The rendered ramp as 0...1 values, one per input step.
    func ramp(_ f: (inout EnhanceSettings) -> Void) throws -> [Double] {
        var p = EnhanceSettings.identity; f(&p)
        let out = try stage.apply(Self.base, settings: p)
        return (0..<Self.steps).map { Double(out.pixels[(4 * Self.steps + $0) * 3]) / 65535.0 }
    }

    func testPositiveBlackPointIsAStraightRemapAndIsMonotone() throws {
        let b = 0.25 // blackPoint 1.0 * 0.25
        let out = try ramp { $0.blackPoint = 1.0 }
        var worst = 0.0
        for i in 0..<Self.steps {
            let x = Double(i) / 255.0
            let expected = x <= b ? 0.0 : (x - b) / (1 - b)
            worst = max(worst, abs(out[i] - expected))
        }
        XCTAssertLessThan(worst, 0.002, "worst deviation from the line was \(worst)")
        for i in 1..<Self.steps {
            XCTAssertGreaterThanOrEqual(out[i], out[i - 1] - 1e-9, "the ramp must be monotone at step \(i)")
        }
    }

    func testNegativeBlackPointIsAStraightLiftAndIsMonotone() throws {
        let lift = 0.20 // -blackPoint -1.0 * -0.20
        let out = try ramp { $0.blackPoint = -1.0 }
        var worst = 0.0
        for i in 0..<Self.steps {
            let x = Double(i) / 255.0
            worst = max(worst, abs(out[i] - (lift + x * (1 - lift))))
        }
        XCTAssertLessThan(worst, 0.002, "worst deviation from the line was \(worst)")
        for i in 1..<Self.steps {
            XCTAssertGreaterThanOrEqual(out[i], out[i - 1] - 1e-9, "the ramp must be monotone at step \(i)")
        }
    }

    /// The midpoint has to move. A curve pinned at (0.5, 0.5) moves p50 by 0.004 at full
    /// slider, which makes Black Point read as running out early.
    func testBlackPointReachesAboveTheMidpoint() throws {
        let up = try ramp { $0.blackPoint = 1.0 }
        let down = try ramp { $0.blackPoint = -1.0 }
        XCTAssertLessThan(up[128], 0.5 - 0.10, "black point + must pull the midpoint down, not just clip the toe")
        XCTAssertGreaterThan(down[128], 0.5 + 0.05, "black point - must lift the midpoint")
    }

    /// The overshoot pinned points cause: at +1 a pinned curve reads 0.6411 where the input
    /// is 0.6275, a wobble of +0.0136 that brightens the upper midtones, and -0.0045 in the
    /// highlights. A straight line cannot do that, and this says so in the
    /// direction that matters: with the black point DOWN, nothing may end up darker than
    /// it started, and with it UP, nothing may end up brighter.
    func testNoSplineOvershootInEitherDirection() throws {
        let down = try ramp { $0.blackPoint = -1.0 }
        let up = try ramp { $0.blackPoint = 1.0 }
        for i in 0..<Self.steps {
            let x = Double(i) / 255.0
            XCTAssertGreaterThanOrEqual(down[i], x - 0.002, "lift dipped below identity at step \(i)")
            XCTAssertLessThanOrEqual(up[i], x + 0.002, "crush rose above identity at step \(i)")
        }
    }
}

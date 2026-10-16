import XCTest
import CoreGraphics
@testable import FilmPositiveCore

/// The white-balance step never silently discards itself.
///
/// Warmth and tint are the x and y of ONE `CITemperatureAndTint` call. Below a source neutral
/// somewhere in (1750 K, 2000 K] that filter returns its input bit for bit, so pushing warmth
/// cool enough throws away the user's TINT as well. Measured: warmth -2 with tint 1.0 came
/// back byte-identical to the untouched control, warmth 0 with tint 1.0 did not, and warmth
/// -2 with saturation 1.0 still saturated, so it is that call vanishing rather than the
/// stage bailing out.
///
/// Unfloored the arithmetic is worse than a dead zone: `6500 + warmth * 2500` reaches 0 K at
/// warmth -2.6 and goes NEGATIVE below it. The typed-value field would let a person walk
/// straight in.
///
/// The floor is chosen conservatively. -1.8 (2000 K) is the coolest setting measured to still
/// work and the cliff sits between there and -1.9, so the floor sits on the last known-good
/// value rather than on an interpolated guess.
final class WarmthFloorTests: XCTestCase {

    private typealias E = CoreImageEnhance

    // MARK: nothing that was ever stored changes

    /// The compatibility claim. `EnhanceControl.range` is -1...1 and is clamped
    /// on write, so no sidecar ever written can hold a warmth below -1.0, which asks for
    /// 4000 K. The floor is therefore unreachable by every existing file and this fix cannot
    /// change a single picture anyone has already made.
    func testEveryWarmthAStoredSidecarCanHoldIsUnaffectedByTheFloor() {
        for hundredths in -100...100 {
            let w = Double(hundredths) / 100.0
            XCTAssertEqual(E.sourceNeutral(warmth: w), 6500 + CGFloat(w) * E.warmthKelvinSpan,
                           accuracy: 0.0001,
                           "warmth \(w) is inside the stored range and must be untouched")
        }
    }

    func testTheRestingValueIsStillD65() {
        XCTAssertEqual(E.sourceNeutral(warmth: 0), 6500, accuracy: 0.0001)
    }

    // MARK: the defect

    /// The exact case measured as byte-identical to doing nothing.
    func testTheDiscardRegionIsFlooredRatherThanRequested() {
        XCTAssertEqual(E.sourceNeutral(warmth: -1.9), 2000, accuracy: 0.0001,
                       "1750 K is where the filter starts returning its input untouched")
        XCTAssertEqual(E.sourceNeutral(warmth: -2.0), 2000, accuracy: 0.0001)
    }

    /// The last setting measured to still work must NOT be clamped, or the fix would cost
    /// real travel rather than only the broken part of it.
    func testTheCoolestWorkingSettingIsNotClamped() {
        XCTAssertEqual(E.sourceNeutral(warmth: -1.8), 2000, accuracy: 0.0001,
                       "-1.8 asks for exactly the floor, so it passes through unchanged")
    }

    /// A color-temperature filter is never handed a value that is not a color
    /// temperature. Unfloored, warmth -2.6 asks for 0 K and -3.0 asks for -1000 K.
    func testNoInputCanProduceAZeroOrNegativeSourceNeutral() {
        for w in [-2.6, -3.0, -10.0, -100.0, -1e6] {
            let k = E.sourceNeutral(warmth: w)
            XCTAssertGreaterThanOrEqual(k, E.minSourceNeutralKelvin,
                                        "warmth \(w) produced \(k) K")
            XCTAssertGreaterThan(k, 0, "warmth \(w) produced a non-physical \(k) K")
        }
    }

    /// The warm direction was measured to have no cliff at all: +7.0 through +10.0 all render
    /// distinct images. So the floor must not have introduced a ceiling on the other side.
    func testTheWarmDirectionIsNotFloored() {
        XCTAssertEqual(E.sourceNeutral(warmth: 1), 9000, accuracy: 0.0001)
        XCTAssertEqual(E.sourceNeutral(warmth: 10), 31500, accuracy: 0.0001)
        XCTAssertGreaterThan(E.sourceNeutral(warmth: 100), E.sourceNeutral(warmth: 10),
                             "the warm side asymptotes in the filter, it is not clamped here")
    }

    /// Monotonic across the whole domain, so a person dragging cool never sees the picture
    /// move backwards before it stops.
    func testTheCurveNeverReverses() {
        var previous = E.sourceNeutral(warmth: -5.0)
        for hundredths in -500...500 {
            let k = E.sourceNeutral(warmth: Double(hundredths) / 100.0)
            XCTAssertGreaterThanOrEqual(k, previous, "reversal at warmth \(Double(hundredths)/100.0)")
            previous = k
        }
    }
}

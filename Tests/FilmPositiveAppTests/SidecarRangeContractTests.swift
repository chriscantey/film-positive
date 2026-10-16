import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Widening what an enhance value may hold must not change what any existing file MEANS.
///
/// Typing a value outside `EnhanceControl.range` widens the track instead of being clipped,
/// so the clamp on write is `storageLimit`. `EnhanceSettings.sliderKeys` is indexed BY
/// POSITION in the XMP codec, so anything that shifts meaning between writer and reader
/// silently rewrites every file ever made.
///
/// WHAT THIS SUITE CAN AND CANNOT PROVE, stated plainly because the gap matters more than
/// the green.
///
/// It exercises `EnhanceControl.setting` and `value` across every value an older sidecar
/// could legally hold, and it checks the positional ordering directly.
///
/// It does NOT round-trip anything through the real codec. `control.setting` followed by
/// `control.value` never touches XMP.
final class SidecarRangeContractTests: XCTestCase {

    // MARK: the positional contract

    /// The hazard, asserted directly. `sliderKeys` is the wire ORDER, and a range
    /// change must not reorder it. This is the cheap guard that would catch a careless edit.
    func testTheWireOrderIsUnchangedByTheRangeWork() {
        // The whole wire order, the retired Richness and the vignette's Size and Softness
        // after it included, since an append is the only change allowed.
        XCTAssertEqual(EnhanceSettings.sliderKeys,
                       ["radiance", "exposure", "highlights", "shadows", "contrast",
                        "brightness", "blackPoint", "vibrance", "saturation", "warmth",
                        "tint", "definition", "sharpness", "noiseReduction", "vignette",
                        "glow", "halation", "softness", "richness", "vignetteSize", "vignetteFeather"],
                       "every sidecar ever written indexes by this order")
    }

    /// Every value an older file could legally hold survives a write and a read unchanged.
    /// 201 values per control across every live control.
    func testEveryLegalPreChangeValueRoundTripsExactly() throws {
        for key in EnhanceControl.liveSliderKeys {
            let control = try XCTUnwrap(EnhanceControl.all.first { $0.id == key })
            for hundredths in -100...100 {
                let v = Double(hundredths) / 100.0
                let written = control.setting(.identity, to: v)
                XCTAssertEqual(control.value(in: written), v, accuracy: 0,
                               "\(key) at \(v) did not survive the write")
            }
        }
    }

    /// The identity has to stay the identity, or a reset means something new.
    func testIdentityIsUntouched() {
        for key in EnhanceSettings.sliderKeys {
            guard let control = EnhanceControl.all.first(where: { $0.id == key }) else { continue }
            XCTAssertEqual(control.value(in: .identity), 0, "\(key) identity moved")
        }
    }

    // MARK: the widening itself

    /// The point of the change: a typed value outside the shown span is KEPT.
    func testAValueOutsideTheShownRangeIsNoLongerClipped() throws {
        let warmth = try XCTUnwrap(EnhanceControl.all.first { $0.id == "warmth" })
        for v in [1.8, -1.8, 5.2, -5.2, 42.0] {
            let written = warmth.setting(.identity, to: v)
            XCTAssertEqual(warmth.value(in: written), v, accuracy: 0,
                           "\(v) was clipped, which is the behaviour being removed")
        }
    }

    /// Not a number never reaches the render graph. `Double("1e400")` is infinity, and
    /// a NaN compares false against everything so a naive clamp passes it straight through.
    func testNonFiniteValuesAreRefusedRatherThanStored() throws {
        let control = try XCTUnwrap(EnhanceControl.all.first { $0.id == "exposure" })
        let start = control.setting(.identity, to: 0.5)
        for bad in [Double.infinity, -.infinity, .nan, Double("1e400")!] {
            let after = control.setting(start, to: bad)
            XCTAssertEqual(control.value(in: after), 0.5, accuracy: 0,
                           "a non-finite value changed the stored setting")
            XCTAssertTrue(control.value(in: after).isFinite)
        }
    }

    /// The guard band exists only to stop infinity, so it must sit far outside anything a
    /// person would type. If this ever fails, the band has become a ceiling.
    func testTheGuardBandIsNowhereNearAnyUsefulValue() {
        XCTAssertGreaterThanOrEqual(EnhanceControl.storageLimit.upperBound, 1000)
        XCTAssertLessThanOrEqual(EnhanceControl.storageLimit.lowerBound, -1000)
        XCTAssertTrue(EnhanceControl.storageLimit.contains(EnhanceControl.range.lowerBound))
        XCTAssertTrue(EnhanceControl.storageLimit.contains(EnhanceControl.range.upperBound))
    }

    // MARK: the shown span

    /// The nominal span is still what a row shows at rest, which is what keeps the simple
    /// path simple. Most people move one or two sliders and are done.
    func testTheRestingSpanIsStillTheOneEveryRowHasAlwaysShown() {
        XCTAssertEqual(EnhanceControl.range, -1...1)
    }

    /// Widening the clamp did not widen the RESTING span. A row that opened to -1000
    /// on its own would make the ordinary case unusable.
    func testWideningStorageDidNotWidenWhatARowShowsAtRest() {
        XCTAssertNotEqual(EnhanceControl.range, EnhanceControl.storageLimit)
        XCTAssertEqual(EnhanceControl.range.upperBound, 1)
    }
}

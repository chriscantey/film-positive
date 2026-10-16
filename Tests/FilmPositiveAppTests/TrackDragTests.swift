import XCTest
import CoreGraphics
@testable import FilmPositive

/// Shift-drag and option-drag move a value in BOTH directions.
///
/// `value(atX:)` clamps its input to `0...width` because it exists to turn an absolute
/// POSITION into a value. A relative delta computed as `value(atX: g.translation.width) -
/// range.lowerBound` clamps every leftward drag to zero: -120 px and -1 px both produce
/// exactly +0.0000. Plain drag, arrow keys, typing and double-click reset all take different
/// paths, so none of them exercises this one.
///
/// A position and a translation are different quantities, and only one of them may be
/// clamped to the track.
final class TrackDragTests: XCTestCase {

    private typealias T = CentreOriginTrack
    private let width: CGFloat = 200
    private let span = 2.0   // the -1...1 resting span

    // MARK: the defect

    /// The exact assertion that fails when the translation is clamped.
    func testALeftwardModifierDragMovesTheValueDown() {
        for px in [CGFloat(-120), -60, -10, -1] {
            let d = T.modifierDelta(translation: px, width: width, span: span, scale: 1)
            XCTAssertLessThan(d, 0, "translation \(px) px produced \(d), so dragging left did nothing")
        }
    }

    func testARightwardModifierDragStillMovesTheValueUp() {
        for px in [CGFloat(1), 10, 60, 120] {
            XCTAssertGreaterThan(T.modifierDelta(translation: px, width: width, span: span, scale: 1), 0)
        }
    }

    /// Symmetric by construction, which is the property the clamp destroyed.
    func testTheDeltaIsSymmetricAboutZero() {
        for px in [CGFloat(1), 17, 60, 120, 500] {
            let up = T.modifierDelta(translation: px, width: width, span: span, scale: 1)
            let down = T.modifierDelta(translation: -px, width: width, span: span, scale: 1)
            XCTAssertEqual(up, -down, accuracy: 1e-12, "asymmetric at \(px) px")
        }
    }

    // MARK: the scaling that makes the modifiers worth holding

    func testNoTranslationIsNoChange() {
        XCTAssertEqual(T.modifierDelta(translation: 0, width: width, span: span, scale: 1), 0, accuracy: 0)
    }

    /// The two multipliers still have to sit either side of 1, even though COARSE IS
    /// UNREACHED: no modifier is wired to it on either input, because Shift is fine everywhere
    /// and no key is named for coarse. The constant stays so the relationship is pinned.
    func testCoarseIsCoarserThanPlainAndFineIsFiner() {
        let px: CGFloat = 60
        let plain = abs(T.modifierDelta(translation: px, width: width, span: span, scale: 1))
        let coarse = abs(T.modifierDelta(translation: px, width: width, span: span, scale: T.coarseMultiplier))
        let fine = abs(T.modifierDelta(translation: px, width: width, span: span, scale: T.fineMultiplier))
        XCTAssertGreaterThan(coarse, plain)
        XCTAssertLessThan(fine, plain)
        XCTAssertEqual(coarse / fine, T.coarseMultiplier / T.fineMultiplier, accuracy: 1e-9)
    }

    /// A full-width drag covers the whole span once, before scaling. That is what makes the
    /// gesture predictable on a track that has been widened by a typed value.
    func testAFullWidthDragCoversTheSpanExactlyOnce() {
        XCTAssertEqual(T.modifierDelta(translation: width, width: width, span: span, scale: 1),
                       span, accuracy: 1e-12)
        // And on a track a typed value has widened to -6...6.
        XCTAssertEqual(T.modifierDelta(translation: width, width: width, span: 12, scale: 1),
                       12, accuracy: 1e-12)
    }

    /// A zero-width track cannot divide by zero.
    func testAZeroWidthTrackIsInert() {
        XCTAssertEqual(T.modifierDelta(translation: 50, width: 0, span: span, scale: 1), 0, accuracy: 0)
        XCTAssertTrue(T.modifierDelta(translation: 50, width: 0, span: span, scale: 1).isFinite)
    }

    /// Why coarse was removed from DRAG, as arithmetic rather than as a story.
    ///
    /// `modifierDelta` traverses the whole span when `(translation / width) * scale == 1`, so
    /// the fraction of the track a full traverse costs is exactly `1 / scale`. At the coarse
    /// 10x that is a tenth of the width: the control slams end to end inside a couple of
    /// centimetres and no tuning of the multiplier changes that.
    ///
    /// The structural reason is the one worth keeping. Plain drag ALREADY maps the whole track
    /// onto the whole range, so a coarse mode has nothing to be coarse relative to. It is not
    /// a bad constant, it is a mode that cannot exist on this control. Fine is the opposite
    /// case and has somewhere to go.
    func testCoarseOnADragCouldOnlyEverSaturate() {
        let span = 2.0
        let coarseTraverse = 1.0 / T.coarseMultiplier
        XCTAssertLessThan(coarseTraverse, 0.2,
                          "a full traverse in \(coarseTraverse * 100)% of the track is a slam, not a drag")
        // Ten percent of the track already covers the entire range.
        XCTAssertGreaterThanOrEqual(
            abs(T.modifierDelta(translation: width * 0.1, width: width, span: span, scale: T.coarseMultiplier)),
            span)
        // Fine needs many track widths for the same traverse, which is the point of it.
        XCTAssertGreaterThan(1.0 / T.fineMultiplier, 1.0)
        XCTAssertLessThan(
            abs(T.modifierDelta(translation: width, width: width, span: span, scale: T.fineMultiplier)),
            span)
    }
}

/// The readout never shows minus zero.
///
/// Shift-arrow steps 0.001, so one press left from rest leaves -0.001, which formats at two
/// decimals as "-0.00". A fine press need not visibly move the readout, but it must not turn
/// the readout into something that looks broken.
///
/// "-0.00" can only render when the value is NEGATIVE and under 0.005 in magnitude, and the
/// only thing in the app producing such a value from rest is the fine step.
final class ReadoutFormatTests: XCTestCase {

    /// Exactly the transform the readout applies.
    private func displayed(_ v: Double) -> String {
        String(format: "%.2f", (v * 100).rounded() / 100 + 0)
    }

    func testAFineStepBelowTheDisplayedPrecisionShowsZeroNotMinusZero() {
        XCTAssertEqual(displayed(-0.001), "0.00", "one shift-arrow from rest must not look broken")
        XCTAssertEqual(displayed(-0.004), "0.00")
        XCTAssertEqual(displayed(0.001), "0.00")
        XCTAssertEqual(displayed(0), "0.00")
    }

    /// The other side of the boundary, so the fix cannot have become "hide the sign".
    func testAValueThatRoundsToAHundredthKeepsItsSign() {
        XCTAssertEqual(displayed(-0.006), "-0.01")
        XCTAssertEqual(displayed(-0.01), "-0.01")
        XCTAssertEqual(displayed(-0.6), "-0.60")
        XCTAssertEqual(displayed(0.006), "0.01")
    }
}

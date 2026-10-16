import XCTest
import CoreGraphics
@testable import FilmPositiveCore

/// Per-folder scale calibration for the anchored route.
///
/// The measurement that motivates this, scored over a set of 114 frames:
/// boxes the sweep measured take up a median 0.7647 of the picture, while boxes the
/// planner BUILT from the expected format take 0.9375, with a tight spread rather than
/// scattered noise. A consistent error with a small spread is a calibration problem.
final class FrameScaleTests: XCTestCase {

    private func result(_ route: AutoCrop.Route, _ r: CGRect,
                        unbounded: Set<CropDetector.Edge> = []) -> AutoCrop.Result {
        AutoCrop.Result(route: route, rect: r, angle: 0, size: nil, unboundedEdges: unbounded)
    }

    private let measured = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.4)

    func testOnlyMeasuredRoutesTeach() {
        var s = FrameScale()
        s.learn(from: result(.plannerAnchored, measured))
        s.learn(from: result(.coarse, measured))
        s.learn(from: result(.frameFinderPartial, measured))
        XCTAssertEqual(s.sampleCount, 0, "a built box must never become evidence about scale")

        s.learn(from: result(.plannerDetected, measured))
        s.learn(from: result(.frameFinderBounded, measured))
        XCTAssertEqual(s.sampleCount, 2)
    }

    /// Two samples is not a median and one is an anecdote. Below the floor the fallback is
    /// left exactly as the planner built it, because a wrong correction is worse than none.
    func testNothingIsCorrectedUntilThereAreEnoughSamples() {
        var s = FrameScale()
        let built = result(.plannerAnchored, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.55))
        for _ in 0..<(FrameScale.minSamples - 1) { s.learn(from: result(.plannerDetected, measured)) }
        XCTAssertFalse(s.isCalibrated)
        XCTAssertEqual(s.refined(built).rect, built.rect)

        s.learn(from: result(.plannerDetected, measured))
        XCTAssertTrue(s.isCalibrated)
        XCTAssertNotEqual(s.refined(built).rect, built.rect)
    }

    /// The correction takes the size the folder has been measuring, which is the whole point.
    func testABuiltBoxIsResizedToWhatTheFolderMeasures() throws {
        var s = FrameScale()
        for _ in 0..<4 { s.learn(from: result(.plannerDetected, measured)) }
        let built = result(.plannerAnchored, CGRect(x: 0.05, y: 0.15, width: 0.85, height: 0.58))
        let out = s.refined(built)
        XCTAssertEqual(out.rect.width, measured.width, accuracy: 1e-9)
        XCTAssertEqual(out.rect.height, measured.height, accuracy: 1e-9)
        XCTAssertEqual(out.route, .plannerAnchored, "correcting the size does not promote it to a measurement")
    }

    /// A measured box is the evidence. Correcting it against a median of itself would only
    /// blur the one thing worth keeping.
    func testAMeasuredBoxIsNeverTouched() {
        var s = FrameScale()
        for _ in 0..<4 { s.learn(from: result(.plannerDetected, measured)) }
        let odd = result(.frameFinderBounded, CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.5))
        XCTAssertEqual(s.refined(odd).rect, odd.rect)
    }

    /// The planner pinned one edge to something it really found. The correction shrinks away
    /// from that edge rather than around the center, so the one piece of evidence in a built
    /// box survives the correction.
    func testTheCorrectionHoldsTheAnchoredEdgeStill() {
        var s = FrameScale()
        for _ in 0..<4 { s.learn(from: result(.plannerDetected, measured)) }
        // Anchored left: every other edge is unbounded.
        let built = result(.plannerAnchored, CGRect(x: 0.05, y: 0.15, width: 0.85, height: 0.58),
                           unbounded: [.right, .top, .bottom])
        let out = s.refined(built)
        XCTAssertEqual(out.rect.minX, 0.05, accuracy: 1e-9, "the found edge must not move")
        XCTAssertEqual(out.rect.width, measured.width, accuracy: 1e-9)
    }

    /// With nothing pinned there is no evidence to hold, so the box shrinks around its middle.
    func testWithNoAnchoredEdgeTheBoxShrinksAboutItsCentre() {
        var s = FrameScale()
        for _ in 0..<4 { s.learn(from: result(.plannerDetected, measured)) }
        let built = result(.plannerAnchored, CGRect(x: 0.05, y: 0.15, width: 0.85, height: 0.58),
                           unbounded: Set(CropDetector.Edge.allCases))
        let out = s.refined(built)
        XCTAssertEqual(out.rect.midX, built.rect.midX, accuracy: 1e-9)
        XCTAssertEqual(out.rect.midY, built.rect.midY, accuracy: 1e-9)
    }
}

import XCTest
import SwiftUI
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Return keeps the crop and puts the rectangle away, Escape puts the frame's geometry back
/// and puts the rectangle away, and the straighten angle rides along with Escape. Plus the
/// straighten readout's typed angle.
final class CropModeKeysTests: XCTestCase {

    private let frameA = URL(fileURLWithPath: "/tmp/roll/A.CR2")
    private let frameB = URL(fileURLWithPath: "/tmp/roll/B.CR2")

    // MARK: which key does what

    func testReturnKeepsAndEscapeCancelsWhileTheRectangleIsUp() {
        XCTAssertEqual(CropModeKeys.action(for: .return, showsCrop: true, dragging: false), .keep)
        XCTAssertEqual(CropModeKeys.action(for: .escape, showsCrop: true, dragging: false), .cancel)
    }

    func testWithTheRectangleDownNeitherKeyIsOurs() {
        // Escape then goes back to the roll, as it always did, and Return does nothing.
        XCTAssertNil(CropModeKeys.action(for: .return, showsCrop: false, dragging: false))
        XCTAssertNil(CropModeKeys.action(for: .escape, showsCrop: false, dragging: false))
    }

    func testADragInFlightOwnsTheKeys() {
        XCTAssertNil(CropModeKeys.action(for: .return, showsCrop: true, dragging: true))
        XCTAssertNil(CropModeKeys.action(for: .escape, showsCrop: true, dragging: true))
    }

    func testOtherKeysAreNotTaken() {
        XCTAssertNil(CropModeKeys.action(for: .leftArrow, showsCrop: true, dragging: false))
        XCTAssertNil(CropModeKeys.action(for: .space, showsCrop: true, dragging: false))
    }

    // MARK: what Escape writes

    func testEscapePutsBackTheCropAndTheStraightenAngle() {
        let entered = GeometrySettings(rotate: 90, flip: false, straightenDegrees: 1.5,
                                       crop: CropRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8))
        let entry = CropModeKeys.Entry(frameID: frameA, geometry: entered)
        let edited = GeometrySettings(rotate: 90, flip: false, straightenDegrees: -3.25,
                                      crop: CropRect(x: 0.2, y: 0.15, w: 0.6, h: 0.7))
        let restored = entry.restoring(edited, on: frameA)
        XCTAssertEqual(restored, entered)
        XCTAssertEqual(restored?.straightenDegrees, 1.5)
    }

    func testEscapeOnAFrameThatHadNoGeometryPutsItBackToNone() {
        let entry = CropModeKeys.Entry(frameID: frameA, geometry: nil)
        let restored = entry.restoring(GeometrySettings(straightenDegrees: 2), on: frameA)
        XCTAssertEqual(restored, GeometrySettings())
        // And the write path stores that as no geometry at all, which is what it was.
        XCTAssertTrue(restored?.isIdentity == true)
    }

    func testEscapeWithNothingChangedWritesNothing() {
        let g = GeometrySettings(straightenDegrees: 0.75)
        XCTAssertNil(CropModeKeys.Entry(frameID: frameA, geometry: g).restoring(g, on: frameA))
        XCTAssertNil(CropModeKeys.Entry(frameID: frameA, geometry: nil).restoring(nil, on: frameA))
        XCTAssertNil(CropModeKeys.Entry(frameID: frameA, geometry: nil).restoring(GeometrySettings(), on: frameA),
                     "no geometry and identity geometry are the same thing on disk")
    }

    func testEscapeNeverWritesOneFramesGeometryOntoAnother() {
        let entry = CropModeKeys.Entry(frameID: frameA, geometry: GeometrySettings(straightenDegrees: 4))
        XCTAssertNil(entry.restoring(GeometrySettings(), on: frameB))
    }

    // MARK: the typed angle

    func testATypedAngleParsesTheWayTheReadoutShowsIt() {
        XCTAssertEqual(CropModeKeys.parseDegrees("1.5"), 1.5)
        XCTAssertEqual(CropModeKeys.parseDegrees("-2"), -2)
        XCTAssertEqual(CropModeKeys.parseDegrees(" 1.25\u{00B0} "), 1.25)
        XCTAssertEqual(CropModeKeys.parseDegrees("0,5"), 0.5)
    }

    func testAnythingThatIsNotAFiniteNumberIsDropped() {
        XCTAssertNil(CropModeKeys.parseDegrees(""))
        XCTAssertNil(CropModeKeys.parseDegrees("level"))
        XCTAssertNil(CropModeKeys.parseDegrees("1e400"))
        XCTAssertNil(CropModeKeys.parseDegrees("nan"))
    }

    /// The field does not clamp. The editor does, so a typed 60 lands at the 45 degree limit
    /// the slider and the rotate band stop at too.
    func testATypedAnglePastTheLimitIsHeldAtTheLimit() throws {
        var editor = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        editor.setDisplayDegrees(try XCTUnwrap(CropModeKeys.parseDegrees("60")))
        XCTAssertEqual(editor.degrees, FineRotation.limitDegrees)
        editor.setDisplayDegrees(try XCTUnwrap(CropModeKeys.parseDegrees("-60")))
        XCTAssertEqual(editor.degrees, -FineRotation.limitDegrees)
    }

    /// On a mirrored frame the readout shows the DISPLAY angle, so a typed value is a display
    /// angle too and is stored negated, the same as the slider's.
    func testATypedAngleOnAMirroredFrameIsADisplayAngle() throws {
        var editor = CropEditor(geometry: GeometrySettings(flip: true), originalAspect: 1.5)
        editor.setDisplayDegrees(try XCTUnwrap(CropModeKeys.parseDegrees("2")))
        XCTAssertEqual(editor.displayDegrees, 2)
        XCTAssertEqual(editor.degrees, -2)
    }
}

import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The aspect lock. A ratio invented per frame gives some frames a wrong crop, so `Original`
/// is the default and the rest are a list.
///
/// Everything here is about one conversion that is easy to get wrong and impossible to see:
/// `displayRect` is normalized 0 to 1 over a canvas that is not square, so a rect with equal
/// width and height is not a square on screen. A lock that forgets that is exactly right on
/// a square image and quietly wrong on every real frame.
final class CropAspectTests: XCTestCase {

    /// On-screen ratio of a normalized rect drawn on a canvas of this aspect.
    private func onScreen(_ r: CGRect, canvas: CGFloat) -> CGFloat {
        (r.width * canvas) / r.height
    }

    func testConstrainingProducesTheTargetRatioOnScreen() {
        let canvas: CGFloat = 3.0 / 2                      // a 3:2 frame
        let start = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        let cases: [(String, CGFloat)] = [("square", 1), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3)]
        for (name, target) in cases {
            let out = CropBox.constrained(start, toAspect: target, canvasAspect: canvas, anchor: .bottomRight)
            XCTAssertEqual(onScreen(out, canvas: canvas), target, accuracy: 0.001,
                           "\(name): the box has to be that ratio where the user can see it, not in normalized units")
        }
    }

    /// The bug this guards: treating normalized width and height as if they were screen
    /// units. On a square canvas the two agree, which is why a wrong implementation passes
    /// a casual test.
    func testTheNormalizedShortcutWouldBeWrongOnANonSquareFrame() {
        let square = CropBox.constrained(CGRect(x: 0, y: 0, width: 0.8, height: 0.8),
                                         toAspect: 1, canvasAspect: 1, anchor: .bottomRight)
        XCTAssertEqual(square.width, square.height, accuracy: 0.001, "on a square canvas they coincide")

        let wide = CropBox.constrained(CGRect(x: 0, y: 0, width: 0.8, height: 0.8),
                                       toAspect: 1, canvasAspect: 3.0 / 2, anchor: .bottomRight)
        XCTAssertNotEqual(wide.width, wide.height, accuracy: 0.001)
        XCTAssertEqual(onScreen(wide, canvas: 3.0 / 2), 1, accuracy: 0.001)
    }

    func testItShrinksRatherThanGrowsSoTheBoxStaysInThePicture() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let targets: [CGFloat] = [1, 16.0 / 9, 3.0 / 2, 4.0 / 3]
        for target in targets {
            let out = CropBox.constrained(full, toAspect: target, canvasAspect: 3.0 / 2, anchor: .bottomRight)
            XCTAssertLessThanOrEqual(out.width, 1.0001, "target \(target)")
            XCTAssertLessThanOrEqual(out.height, 1.0001, "target \(target)")
            XCTAssertGreaterThanOrEqual(out.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(out.minY, -0.0001)
        }
    }

    func testTheAnchorCornerHoldsStill() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let canvas: CGFloat = 3.0 / 2

        let br = CropBox.constrained(start, toAspect: 1, canvasAspect: canvas, anchor: .bottomRight)
        XCTAssertEqual(br.minX, start.minX, accuracy: 0.0001, "dragging the bottom right holds the top left")
        XCTAssertEqual(br.minY, start.minY, accuracy: 0.0001)

        let tl = CropBox.constrained(start, toAspect: 1, canvasAspect: canvas, anchor: .topLeft)
        XCTAssertEqual(tl.maxX, start.maxX, accuracy: 0.0001, "dragging the top left holds the bottom right")
        XCTAssertEqual(tl.maxY, start.maxY, accuracy: 0.0001)

        let centred = CropBox.constrained(start, toAspect: 1, canvasAspect: canvas, anchor: nil)
        XCTAssertEqual(centred.midX, start.midX, accuracy: 0.0001, "no handle means about the centre")
        XCTAssertEqual(centred.midY, start.midY, accuracy: 0.0001)
    }

    func testFreeformDoesNotTouchTheBox() {
        XCTAssertNil(CropAspect.freeform.targetAspect(original: 1.5))
        XCTAssertNil(CropAspect.freeform.targetAspect(original: 1.5, portrait: false))
    }

    func testOriginalFollowsTheFrameAndTheOthersFollowItsOrientation() {
        XCTAssertEqual(CropAspect.original.targetAspect(original: 1.5), 1.5)
        XCTAssertEqual(CropAspect.original.targetAspect(original: 0.667, portrait: true) ?? 0, 0.667, accuracy: 0.001,
                       "Original is already the frame's own shape, either way up")

        // A portrait frame wants the portrait form of a landscape ratio.
        XCTAssertEqual(CropAspect.sixteenNine.targetAspect(original: 0.667, portrait: true) ?? 0,
                       9.0 / 16, accuracy: 0.001)
        XCTAssertEqual(CropAspect.sixteenNine.targetAspect(original: 1.5, portrait: false) ?? 0,
                       16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(CropAspect.square.targetAspect(original: 0.667, portrait: true) ?? 0, 1, accuracy: 0.001,
                       "a square is a square either way up")
    }

    func testDegenerateInputIsReturnedUntouchedRatherThanDividedBy() {
        let r = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertEqual(CropBox.constrained(r, toAspect: 0, canvasAspect: 1.5, anchor: nil), r)
        XCTAssertEqual(CropBox.constrained(r, toAspect: 1.5, canvasAspect: 0, anchor: nil), r)
        XCTAssertEqual(CropBox.constrained(.zero, toAspect: 1.5, canvasAspect: 1.5, anchor: nil), .zero)
    }
}

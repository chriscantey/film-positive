import XCTest
import CoreGraphics
@testable import FilmPositive

/// The capsule's value edge never shows at the box's rounded end.
///
/// On a row reading 1.00 an unfaded edge sits in the last 2 pt of the box, which is all
/// corner, as two stubs above and below the readout, and the clip to the box trims them to
/// two pink crescents on the curve, beside the reset glyph. In bounds and still wrong, so a
/// clip alone cannot fix it.
///
/// The edge fades over one corner radius and is gone at either end of the span. These assert
/// that on the geometry the view draws from, at widths that land on different pixel phases,
/// because a sliver lives in the fractions.
final class CapsuleEdgeTests: XCTestCase {

    private typealias T = CentreOriginTrack
    /// Whole, half and quarter point widths, so the end falls on every 2x pixel phase.
    private let widths: [CGFloat] = [200, 200.25, 200.5, 213.75, 247.3]

    private func edge(_ fraction: Double, width w: CGFloat) -> (x: CGFloat, opacity: Double) {
        T.valueEdge(valueX: CGFloat(fraction) * w, neutralX: w / 2, width: w)
    }

    /// The reported case: a value at the top of its span draws no edge at all.
    func testAtTheUpperEndTheEdgeIsGone() {
        for w in widths {
            XCTAssertEqual(edge(1, width: w).opacity, 0, accuracy: 0, "an edge still drawn at 1.00, width \(w)")
        }
    }

    /// And the lower end, where a negative value meets the left corner.
    func testAtTheLowerEndTheEdgeIsGone() {
        for w in widths {
            XCTAssertEqual(edge(0, width: w).opacity, 0, accuracy: 0, "an edge still drawn at -1.00, width \(w)")
        }
    }

    /// Anywhere clear of the corners the edge is drawn at full strength, so the fade never dims
    /// an ordinary value.
    func testClearOfTheCornersTheEdgeIsFull() {
        for w in widths {
            for f in [0.1, 0.25, 0.4, 0.6, 0.75, 0.9] {
                XCTAssertEqual(edge(f, width: w).opacity, 1, accuracy: 0, "dimmed at \(f) on width \(w)")
            }
        }
    }

    /// Every point of the edge that is drawn at all sits inside the box.
    func testTheEdgeNeverLeavesTheBox() {
        for w in widths {
            for i in 0...1000 {
                let e = edge(Double(i) / 1000, width: w)
                guard e.opacity > 0 else { continue }
                XCTAssertGreaterThanOrEqual(e.x, 0)
                XCTAssertLessThanOrEqual(e.x + T.capsuleEdgeWidth, w)
            }
        }
    }

    /// Continuous into the end, with no pop: approaching the upper end, the opacity only ever
    /// falls, and no single 1/1000 step of the span changes it by more than a small amount.
    func testTheFadeIsMonotonicAndContinuous() {
        for w in widths {
            var last = 1.0
            for i in 750...1000 {
                let o = edge(Double(i) / 1000, width: w).opacity
                XCTAssertLessThanOrEqual(o, last + 1e-12, "the edge brightened near the end at width \(w)")
                XCTAssertLessThan(last - o, 0.05, "the edge popped near the end at width \(w)")
                last = o
            }
        }
    }

    /// The fade spans exactly the rounded corner and no more, measured from the edge's outer
    /// side, which is the value's own x: full where the value enters the corner, half way at
    /// half the radius, gone at the end.
    func testTheFadeSpansTheCorner() {
        let w: CGFloat = 200
        let r = T.capsuleRadius
        func at(_ xv: CGFloat) -> Double { T.valueEdge(valueX: xv, neutralX: w / 2, width: w).opacity }
        XCTAssertEqual(at(w - r - 0.25), 1, accuracy: 0)
        XCTAssertEqual(at(w - r), 1, accuracy: 1e-12)
        XCTAssertEqual(at(w - r / 2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(at(w), 0, accuracy: 0)
    }
}

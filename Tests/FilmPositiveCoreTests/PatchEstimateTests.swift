import XCTest
import CoreGraphics
import FilmSidecar
@testable import FilmPositiveCore

/// `Calibrator.patchEstimate`, the eyedropper's measurement.
///
/// Graded the way the rest of `Calibrator` is graded: on synthetic frames whose values the
/// test chooses, so what is asserted is that the estimator recovers numbers that are known
/// by construction rather than numbers somebody read off a real roll once.
final class PatchEstimateTests: XCTestCase {

    /// A frame whose pixels come from a closure, so a test can paint a patch of known
    /// values into a background of something else.
    private func frame(width: Int, height: Int,
                       _ value: (Int, Int) -> (UInt16, UInt16, UInt16)) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = value(x, y)
                let i = (y * width + x) * 3
                px[i] = r; px[i + 1] = g; px[i + 2] = b
            }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }

    /// The round trip: a patch of known mean comes back within one code
    /// value. Flat inside the patch and very different outside it, so a mapping error or an
    /// off-by-one in the bounds would show up as a mean pulled toward the surround rather
    /// than as a subtle drift.
    func testAKnownPatchMeanRoundTripsWithinOneCodeValue() throws {
        let w = 800, h = 600
        // The patch: centered on (0.25, 0.75), which is asymmetric in both axes so a
        // transposed x and y would fail rather than pass by symmetry.
        let radius = 0.02
        let cx = 0.25, cy = 0.75
        let halfPixels = Double(w) * radius
        let inside: (Double, Double) -> Bool = { x, y in
            abs(x - cx * Double(w)) <= halfPixels + 3 && abs(y - cy * Double(h)) <= halfPixels + 3
        }
        let f = frame(width: w, height: h) { x, y in
            inside(Double(x) + 0.5, Double(y) + 0.5) ? (12000, 26000, 41000) : (60000, 1000, 3000)
        }

        let m = try XCTUnwrap(Calibrator.patchEstimate(f, at: CGPoint(x: cx, y: cy), radius: radius))
        XCTAssertEqual(m[0], 12000, accuracy: 1, "red mean")
        XCTAssertEqual(m[1], 26000, accuracy: 1, "green mean")
        XCTAssertEqual(m[2], 41000, accuracy: 1, "blue mean")
    }

    /// The patch's extent comes from the frame WIDTH in BOTH axes, so it covers the same
    /// pixel count each way on a frame that is not square.
    ///
    /// Asserted against a value that only comes out right at the correct vertical extent.
    /// The frame is painted in horizontal bands: one value for the 40 rows nearest the
    /// center and a very different one outside them. A width-derived half of 36 pixels
    /// reads 72 rows, 40 of one band and 32 of the other, so the mean is a specific
    /// mixture. A half derived from the HEIGHT instead would be 12 pixels, read 24 rows,
    /// and every one of them would sit inside the inner band, so it would return that
    /// band's values unmixed. The two answers are thousands of code values apart.
    func testThePatchExtentComesFromTheWidthInBothAxes() throws {
        let w = 1200, h = 400
        let radius = 0.03                       // 36 px each way off a 1200 px width
        let inner: (Double, Double, Double) = (5000, 20000, 9000)
        let outer: (Double, Double, Double) = (0, 64000, 0)
        let f = frame(width: w, height: h) { _, y in
            abs(Double(y) + 0.5 - 200) <= 20
                ? (UInt16(inner.0), UInt16(inner.1), UInt16(inner.2))
                : (UInt16(outer.0), UInt16(outer.1), UInt16(outer.2))
        }
        let m = try XCTUnwrap(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: radius))
        // Rows 164 up to 236: 40 inner (180 to 219) and 32 outer.
        let mix: (Double, Double) -> Double = { a, b in (40 * a + 32 * b) / 72 }
        XCTAssertEqual(m[0], mix(inner.0, outer.0), accuracy: 0.01, "red")
        XCTAssertEqual(m[1], mix(inner.1, outer.1), accuracy: 0.01, "green")
        XCTAssertEqual(m[2], mix(inner.2, outer.2), accuracy: 0.01, "blue")
        // And the wrong answer, named, so a future reader knows what this guards.
        XCTAssertNotEqual(m[1], inner.1, accuracy: 1,
                          "a height-derived radius would have returned the inner band alone")
    }

    /// A patch that is entirely at the sensor ceiling returns nil, not a mean of the
    /// ceiling. This is the case that matters in the app: the bare light between the
    /// sprockets is at the ADC ceiling, and a mean of ceiling values would be a measurement
    /// of the lamp rather than of the film, written to the user's sidecar as a base.
    func testAClippedPatchRefuses() {
        let f = frame(width: 600, height: 600) { _, _ in (65535, 65535, 65535) }
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: 0.05))
    }

    /// One channel at the ceiling loses the WHOLE pixel, exactly as `rebateEstimate` does
    /// it, because a partial pixel biases the ratios. Half the patch clipped in red only,
    /// and the mean of the surviving half is what comes back.
    func testAPixelWithOneClippedChannelIsDroppedEntirely() throws {
        let w = 600, h = 600
        let f = frame(width: w, height: h) { x, _ in
            x < w / 2 ? (65100, 30000, 30000) : (10000, 20000, 40000)
        }
        // Centered in the right half, so nothing clipped is in range at all: the control.
        let clean = try XCTUnwrap(Calibrator.patchEstimate(f, at: CGPoint(x: 0.75, y: 0.5), radius: 0.02))
        XCTAssertEqual(clean[0], 10000, accuracy: 1)

        // Straddling the seam: the clipped half is dropped whole, so the mean is still the
        // clean half's values rather than an average of the two.
        let straddling = try XCTUnwrap(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: 0.02))
        XCTAssertEqual(straddling[0], 10000, accuracy: 1, "red, with the clipped pixels dropped")
        XCTAssertEqual(straddling[1], 20000, accuracy: 1, "green too, not 25000")
        XCTAssertEqual(straddling[2], 40000, accuracy: 1, "and blue")
    }

    /// Too few clean pixels refuses. A one-pixel-wide frame cannot hold 100 pixels however
    /// the square is placed, which is the cheapest way to reach the guard without also
    /// changing the clip state.
    func testTooFewCleanPixelsRefuses() {
        let f = frame(width: 4, height: 4) { _, _ in (1000, 2000, 3000) }
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: 0.02))
        XCTAssertEqual(Calibrator.minPatchPixels, 100)
    }

    /// The degenerate inputs the UI can hand it. A click cannot produce these, but a bad
    /// mapping could, and the estimator is the last thing between a bad number and the
    /// user's file.
    func testNonFiniteAndOffFrameInputsRefuse() {
        let f = frame(width: 600, height: 600) { _, _ in (1000, 2000, 3000) }
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: .nan, y: 0.5), radius: 0.02))
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: .infinity), radius: 0.02))
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: 0))
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: 5, y: 0.5), radius: 0.02),
                     "a point well off the frame has no pixels in range")
    }
}

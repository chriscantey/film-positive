import XCTest
@testable import FilmPositiveCore

/// The perceptual metric the render criteria are stated in has to be right before it can
/// certify anything, so it is checked against the CIE's own published test data before it
/// is pointed at a single frame. A ΔE implementation with a sign error still returns small
/// numbers on near-identical frames, which is exactly the case it would be used to certify.
final class DeltaE2000Tests: XCTestCase {

    /// Sharma, Wu and Dalal (2005), the sample data distributed with the CIEDE2000 paper.
    /// These pairs are chosen to exercise the hue rotation and the arc wraparound, which is
    /// where a naive implementation is wrong.
    func testAgainstSharmaWuDalalSamples() {
        let cases: [(Double, Double, Double, Double, Double, Double, Double)] = [
            (50.0000, 2.6772, -79.7751, 50.0000, 0.0000, -82.7485, 2.0425),
            (50.0000, 3.1571, -77.2803, 50.0000, 0.0000, -82.7485, 2.8615),
            (50.0000, 2.8361, -74.0200, 50.0000, 0.0000, -82.7485, 3.4412),
            (50.0000, -1.3802, -84.2814, 50.0000, 0.0000, -82.7485, 1.0000),
            (50.0000, -1.1848, -84.8006, 50.0000, 0.0000, -82.7485, 1.0000),
            (50.0000, -0.9009, -85.5211, 50.0000, 0.0000, -82.7485, 1.0000),
            (50.0000, 0.0000, 0.0000, 50.0000, -1.0000, 2.0000, 2.3669),
            (50.0000, -1.0000, 2.0000, 50.0000, 0.0000, 0.0000, 2.3669),
            (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0009, 7.1792),
            (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0010, 7.1792),
            (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0011, 7.2195),
            (50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0012, 7.2195),
            (50.0000, -0.0010, 2.4900, 50.0000, 0.0009, -2.4900, 4.8045),
            (50.0000, -0.0010, 2.4900, 50.0000, 0.0011, -2.4900, 4.7461),
            (50.0000, 2.5000, 0.0000, 50.0000, 0.0000, -2.5000, 4.3065),
            (50.0000, 2.5000, 0.0000, 73.0000, 25.0000, -18.0000, 27.1492),
            (50.0000, 2.5000, 0.0000, 61.0000, -5.0000, 29.0000, 22.8977),
            (50.0000, 2.5000, 0.0000, 56.0000, -27.0000, -3.0000, 31.9030),
            (50.0000, 2.5000, 0.0000, 58.0000, 24.0000, 15.0000, 19.4535),
            (50.0000, 2.5000, 0.0000, 50.0000, 3.1736, 0.5854, 1.0000),
            (50.0000, 2.5000, 0.0000, 50.0000, 3.2972, 0.0000, 1.0000),
            (50.0000, 2.5000, 0.0000, 50.0000, 1.8634, 0.5757, 1.0000),
            (50.0000, 2.5000, 0.0000, 50.0000, 3.2592, 0.3350, 1.0000),
            (60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644),
            (63.0109, -31.0961, -5.8663, 62.8187, -29.7946, -4.0864, 1.2630),
            (61.2901, 3.7196, -5.3901, 61.4292, 2.2480, -4.9620, 1.8731),
            (35.0831, -44.1164, 3.7933, 35.0232, -40.0716, 1.5901, 1.8645),
            (22.7233, 20.0904, -46.6940, 23.0331, 14.9730, -42.5619, 2.0373),
            (36.4612, 47.8580, 18.3852, 36.2715, 50.5065, 21.2231, 1.4146),
            (90.8027, -2.0831, 1.4410, 91.1528, -1.6435, 0.0447, 1.4441),
            (90.9257, -0.5406, -0.9208, 88.6381, -0.8985, -0.7239, 1.5381),
            (6.7747, -0.2908, -2.4247, 5.8714, -0.0985, -2.2286, 0.6377),
            (2.0776, 0.0795, -1.1350, 0.9033, -0.0636, -0.5514, 0.9082),
        ]
        for (l1, a1, b1, l2, a2, b2, expected) in cases {
            let got = DeltaE2000.delta((l1, a1, b1), (l2, a2, b2))
            XCTAssertEqual(got, expected, accuracy: 0.0001,
                           "ΔE2000 for (\(l1), \(a1), \(b1)) and (\(l2), \(a2), \(b2))")
        }
    }

    /// The color conversion in front of the formula: sRGB primaries and white land where
    /// the standard says, so a frame's numbers enter the metric correctly.
    func testSRGBToLabLandmarks() {
        let white = DeltaE2000.lab(65535, 65535, 65535)
        XCTAssertEqual(white.0, 100, accuracy: 0.01)
        XCTAssertEqual(white.1, 0, accuracy: 0.01)
        XCTAssertEqual(white.2, 0, accuracy: 0.01)

        let black = DeltaE2000.lab(0, 0, 0)
        XCTAssertEqual(black.0, 0, accuracy: 0.001)

        // sRGB red, the standard's published Lab value
        let red = DeltaE2000.lab(65535, 0, 0)
        XCTAssertEqual(red.0, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.1, 80.09, accuracy: 0.05)
        XCTAssertEqual(red.2, 67.20, accuracy: 0.05)

        // mid grey is neutral: a and b are zero whatever the transfer function does
        let grey = DeltaE2000.lab(32768, 32768, 32768)
        XCTAssertEqual(grey.1, 0, accuracy: 0.001)
        XCTAssertEqual(grey.2, 0, accuracy: 0.001)
    }

    /// The metric can fail. A frame differing by one code value is under a thousandth of a
    /// ΔE, and one differing by a visible amount is over 1, so a threshold of 0.2 is a real
    /// gate rather than a number nothing can trip.
    func testTheMetricSeparatesInvisibleFromVisible() throws {
        let w = 64, h = 64
        var a = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            a[i * 3] = UInt16(20000 + i % 1000)
            a[i * 3 + 1] = UInt16(30000 + i % 500)
            a[i * 3 + 2] = UInt16(40000 + i % 250)
        }
        let base = DecodedFrame(width: w, height: h, pixels: a)

        var oneCodeValue = a
        for i in stride(from: 0, to: oneCodeValue.count, by: 3) { oneCodeValue[i] += 1 }
        let tiny = try XCTUnwrap(DeltaE2000.compare(base, DecodedFrame(width: w, height: h, pixels: oneCodeValue), stride: 1))
        XCTAssertLessThan(tiny.max, 0.01, "one code value should be far under the gate: \(tiny)")

        var visible = a
        for i in stride(from: 0, to: visible.count, by: 3) { visible[i] = visible[i] &+ 1200 }
        let big = try XCTUnwrap(DeltaE2000.compare(base, DecodedFrame(width: w, height: h, pixels: visible), stride: 1))
        XCTAssertGreaterThan(big.max, 1.0, "a visible shift has to trip the gate: \(big)")
        XCTAssertNil(DeltaE2000.compare(base, DecodedFrame(width: 8, height: 8, pixels: [UInt16](repeating: 0, count: 192))))
    }
}

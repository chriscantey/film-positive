import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The base measurement, graded on synthetic frames whose answer this file chose.
///
/// A measurement is exactly the kind of code a captured reference cannot grade. Comparing
/// its output against numbers a previous implementation produced on a real roll says the two
/// agree. It never says either one recovered the film. So every frame here is built from a
/// base picked in the test, and what is asserted is that `Calibrator` hands that base back.
///
/// The frames are small, in memory, and handed to `measureBase` through its `read` seam, so
/// the whole suite runs in milliseconds and on any machine.
final class CalibratorTests: XCTestCase {

    // MARK: building a roll

    /// One synthetic negative.
    ///
    /// The outer sprocket margins (the top and bottom `rebateMargin` of the height) carry
    /// clear film base at `base`, plus sprocket holes of bare backlight at the sensor ceiling.
    /// The bare light has to be there: `rebateEstimate` looks for the largest green cluster
    /// BELOW 97 percent of the brightest thing in the margins, which is how it tells film
    /// base from light leaking past the film, so a margin holding nothing but base has no
    /// cluster it will accept. That is the estimator's own rule and this frame is built to
    /// satisfy it rather than around it.
    ///
    /// The picture area is flat at `exposed`, so each channel's density is exactly
    /// `log10(base_c / exposed_c)` at every sample and the P99.5 the fitter takes is that
    /// number with no percentile ambiguity at all.
    private func negative(base: [UInt16], exposed: [UInt16], width w: Int = 320, height h: Int = 240,
                          lightColumns: Int = 14) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        let yTop = Int((Double(h) * Calibrator.rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - Calibrator.rebateMargin)).rounded(.up))
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let inMargin = y < yTop || y >= yBot
                if inMargin {
                    // Sprocket holes of bare backlight every 36 px, a ninth of the width.
                    // A reading needs them (`stripsShowSprocketHoles`).
                    if x % 36 < lightColumns {
                        for c in 0..<3 { px[i + c] = 65_535 }          // bare backlight
                    } else {
                        for c in 0..<3 { px[i + c] = base[c] }          // clear film base
                    }
                } else {
                    for c in 0..<3 { px[i + c] = exposed[c] }
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    private func roll(_ frames: [DecodedFrame]) -> (frames: [Calibrator.Frame], read: (URL) throws -> DecodedFrame) {
        var table: [String: DecodedFrame] = [:]
        var list: [Calibrator.Frame] = []
        for (i, f) in frames.enumerated() {
            let url = URL(fileURLWithPath: "/synthetic/frame-\(i).ppm")
            table[url.path] = f
            list.append(Calibrator.Frame(name: url.lastPathComponent, url: url, role: .image))
        }
        return (list, { url in
            guard let f = table[url.path] else { throw Calibrator.CalibrationError.noRebateFound }
            return f
        })
    }

    // MARK: the rebate estimator

    /// `rebateEstimate` recovers the border value it was given, per channel, exactly.
    ///
    /// This is the measurement the render reaches for when Find film edge is on, so it is
    /// stated on its own: a frame whose margins are a known constant must come back as that
    /// constant.
    func testRebateEstimateRecoversTheBorderItWasGiven() throws {
        let base: [UInt16] = [18_000, 40_000, 30_000]
        let f = negative(base: base, exposed: [1_800, 4_000, 3_000])
        let got = try XCTUnwrap(Calibrator.rebateEstimate(f))
        for c in 0..<3 {
            XCTAssertEqual(got[c], Double(base[c]), accuracy: 0.5, "channel \(c)")
        }
    }

    /// And it refuses rather than guesses. A frame with no margin to read (every row inside
    /// the picture area) yields nothing, which is what lets the render fall back to the
    /// prior instead of inventing a base.
    func testRebateEstimateRefusesAFrameWithNoReadableMargin() {
        let flat = DecodedFrame(width: 320, height: 240, pixels: [UInt16](repeating: 4_000, count: 320 * 240 * 3))
        XCTAssertNil(Calibrator.rebateEstimate(flat), "a frame with no cluster below the cap has no rebate")
        let tiny = DecodedFrame(width: 8, height: 8, pixels: [UInt16](repeating: 40_000, count: 8 * 8 * 3))
        XCTAssertNil(Calibrator.rebateEstimate(tiny), "too few clean pixels to measure")
    }

    // MARK: the roll base measurement

    /// The refusal, which is the half a fitter is judged on. Two sessions under different
    /// lights have different base pairs, and mixing them has to come back `poor` rather
    /// than as a confident average of two answers.
    func testTwoSessionsUnderDifferentLightsAreCalledPoor() throws {
        let sessionA: [UInt16] = [18_000, 40_000, 30_000]          // R/G 0.450
        let sessionB: [UInt16] = [24_000, 40_000, 26_000]          // R/G 0.600
        let exposed: [UInt16] = [3_600, 4_000, 2_000]
        let (frames, read) = roll([
            negative(base: sessionA, exposed: exposed, lightColumns: 12),
            negative(base: sessionA, exposed: exposed, lightColumns: 16),
            negative(base: sessionB, exposed: exposed, lightColumns: 12),
            negative(base: sessionB, exposed: exposed, lightColumns: 16),
        ])
        let measured = try Calibrator.measureBase(frames, read: read)
        XCTAssertEqual(measured.quality.framesUsed, 4)
        XCTAssertGreaterThan(measured.quality.spreadPct, Calibrator.qualityFairMax,
                             "a 25 percent disagreement in red has to show up as spread")
        XCTAssertEqual(measured.quality.verdict, .poor, "mixed sessions are not a fit")
    }

    /// A dedicated blank base frame is measured from its center rather than its margins,
    /// and it is preferred over the rebate route whenever the selection holds one.
    func testADedicatedBaseFrameIsMeasuredFromItsCentre() throws {
        let base: [UInt16] = [18_000, 40_000, 30_000]
        let blank = DecodedFrame(width: 320, height: 240,
                                 pixels: (0..<(320 * 240)).flatMap { _ in base })
        let url = URL(fileURLWithPath: "/synthetic/blank.ppm")
        let picture = negative(base: [9_000, 20_000, 15_000], exposed: [900, 2_000, 1_500])
        let pictureURL = URL(fileURLWithPath: "/synthetic/picture.ppm")
        let frames = [Calibrator.Frame(name: "blank", url: url, role: .base),
                      Calibrator.Frame(name: "picture", url: pictureURL, role: .image)]
        let m = try Calibrator.measureBase(frames) { $0 == url ? blank : picture }
        XCTAssertEqual(m.method, .baseFrames, "a blank base frame beats the sprocket margins")
        for c in 0..<3 { XCTAssertEqual(m.base[c], Double(base[c]), accuracy: 0.5, "channel \(c)") }
        XCTAssertEqual(m.ratios.rg, Double(base[0]) / Double(base[1]), accuracy: 1e-9)
    }

    // MARK: the rules a synthetic frame cannot reach

    func testMedianTakesTheUpperMiddleOnAnEvenCount() {
        // `sorted[count / 2]` on an even count is the UPPER middle, never the mean of the
        // two middles. Six frames is an even count and this choice is what picks the
        // combined base.
        XCTAssertEqual(Calibrator.median([4, 1, 3, 2]), 3)
        XCTAssertEqual(Calibrator.median([1, 2, 3]), 2)
        XCTAssertEqual(Calibrator.median([33726.3, 33983.5, 34363.1, 53186.8, 54717.3, 56126.1]), 53186.8)
    }

    /// `fixed` rounds the EXACT binary value of a double, which is not what scaling by a
    /// power of ten and rounding does. Two of these four round DOWN from what a decimal
    /// reading of the literal suggests, because the double underneath is a hair below the
    /// half.
    func testFixedRoundsTheBinaryValueAndNotTheDecimalItLooksLike() {
        XCTAssertEqual(Calibrator.fixed(1.2345, 3), 1.234, "1.2345 is stored as 1.23449999999999993")
        XCTAssertEqual(Calibrator.fixed(32.785, 2), 32.78, "32.785 is stored as 32.78499999999999659")
        XCTAssertEqual(Calibrator.fixed(0.46513832664173405, 5), 0.46514)
        XCTAssertEqual(Calibrator.fixed(0.4849, 2), 0.48)
    }

    func testQualityThresholdsAreTheDocumentedOnes() {
        // Two estimates at a 2.0 percent spread is the last good one; 6.0 the last fair.
        func spread(_ pct: Double) -> Calibrator.Quality {
            let lo = 1.0, hi = 1.0 + pct / 100
            return Calibrator.quality(perFrame: [[lo, 1, 1], [hi, 1, 1]])
        }
        XCTAssertEqual(spread(1.9).verdict, .good)
        XCTAssertEqual(spread(5.0).verdict, .fair)
        XCTAssertEqual(spread(7.0).verdict, .poor)
        XCTAssertEqual(Calibrator.quality(perFrame: [[1, 1, 1]]).verdict, .fair,
                       "one estimate has no spread to judge, so it gets the honest middle verdict")
    }

    func testAnEmptySelectionIsRefusedRatherThanFitted() {
        XCTAssertThrowsError(try Calibrator.measureBase([]))
        let flats = [Calibrator.Frame(name: "f", url: URL(fileURLWithPath: "/dev/null"), role: .flat)]
        XCTAssertThrowsError(try Calibrator.measureBase(flats))
    }
}

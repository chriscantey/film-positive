import XCTest
import CoreGraphics
import FilmPositiveCore

/// The film-edge reader and the eyedropper on scans whose sprocket-hole light does not clip
/// (a set of May 800T and Azure rolls), and the guarantee that every clipped roll still reads
/// by the old rule, bit for bit.
///
/// Every frame is synthetic, so the base each test expects is the base it painted.
final class SprocketHoleRebateTests: XCTestCase {
    /// A dense base like the May 800T's, about a quarter of the lamp.
    let base: [UInt16] = [9000, 10000, 4200]
    /// A base a clipped roll carries: above 0.3 of the ADC ceiling, where the old rule looks.
    let clippedRollBase: [UInt16] = [22000, 25000, 11000]
    let picture: [UInt16] = [3000, 3000, 3000]
    let w = 1280, h = 800
    /// Holes are 48 px wide on a 144 px pitch (a ninth of the width, as on 35 mm), in rows
    /// 8 to 55 of each strip's 72.
    let holeWidth = 48, pitch = 144, holeRows = 8..<56

    func isHole(_ x: Int, _ yInStrip: Int) -> Bool {
        holeRows.contains(yInStrip) && x % pitch >= 20 && x % pitch < 20 + holeWidth
    }

    /// A negative with sprocket holes in both margins. `lamp` is the green through a hole at
    /// the left edge, falling off by `falloff` across the frame, with the lamp's own color
    /// (R/G 0.525, B/G 0.675). `clipHoles` puts every hole at the sensor ceiling instead.
    /// `holes: false` paints a contiguous bright band where the holes would be, which is a
    /// light leak along the edge rather than sprocket holes.
    func negative(lamp: Double = 40000, falloff: Double = 0.15, clipHoles: Bool = false,
                  holes: Bool = true, hotPixels: Int = 0, base: [UInt16]? = nil) -> DecodedFrame {
        let base = base ?? self.base
        var px = [UInt16](repeating: 0, count: w * h * 3)
        let yTop = Int((Double(h) * Calibrator.rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - Calibrator.rebateMargin)).rounded(.up))
        var hot = hotPixels
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let inStrip = y < yTop || y >= yBot
                let ys = y < yTop ? y : y - yBot
                let light = holes ? isHole(x, ys) : holeRows.contains(ys)
                if inStrip && light {
                    if clipHoles {
                        for c in 0..<3 { px[i + c] = 65_535 }
                    } else {
                        let g = lamp * (1 - falloff * Double(x) / Double(w))
                        px[i] = UInt16(g * 0.525); px[i + 1] = UInt16(g); px[i + 2] = UInt16(g * 0.675)
                        if hot > 0 && y % 2 == 0 && x % 2 == 0 { px[i + 1] = 65_535; hot -= 1 }
                    }
                } else if inStrip {
                    for c in 0..<3 { px[i + c] = base[c] }
                } else {
                    for c in 0..<3 { px[i + c] = picture[c] }
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    func assertBase(_ e: [Double]?, _ message: String, base: [UInt16]? = nil,
                    file: StaticString = #filePath, line: UInt = #line) {
        let base = base ?? self.base
        guard let e else { return XCTFail("nil: \(message)", file: file, line: line) }
        for c in 0..<3 { XCTAssertEqual(e[c], Double(base[c]), accuracy: 1e-9, message, file: file, line: line) }
    }

    // MARK: the edge reader

    /// The bug, reproduced: with the lamp unclipped the old rule's cap is the lamp, the
    /// rebate sits under its 0.3 floor, and the holes dimmed by falloff become the peak.
    func testTheOldRuleReadsTheLampWhenTheHolesDoNotClip() throws {
        let e = try XCTUnwrap(Calibrator.clippedLampEstimate(negative()))
        XCTAssertEqual(e[0] / e[1], 0.525, accuracy: 0.002, "the old rule reads the lamp's R/G")
        XCTAssertEqual(e[2] / e[1], 0.675, accuracy: 0.002, "the old rule reads the lamp's B/G")
    }

    func testUnclippedHolesReadTheRebateBelowThem() {
        let reading = Calibrator.rebateReading(negative())
        XCTAssertEqual(reading.path, .belowHoles)
        assertBase(reading.estimate, "the rebate the frame was painted with")
        assertBase(Calibrator.rebateEstimate(negative()), "rebateEstimate is the same reading")
    }

    func testTheReaderDoesNotDependOnTheLampsBrightnessOrColour() {
        // At 20000 and 30000 the rebate is half and a third of the lamp, inside the old
        // rule's window, so the old rule reads it and keeps it. At 60000 only the new one can.
        for (lamp, path) in [(20000.0, Calibrator.RebatePath.capRule), (30000, .capRule), (60000, .belowHoles)] {
            let reading = Calibrator.rebateReading(negative(lamp: lamp, falloff: 0.25))
            XCTAssertEqual(reading.path, path, "lamp \(lamp)")
            assertBase(reading.estimate, "lamp \(lamp)")
        }
    }

    /// The invariance guarantee: a clipped lamp takes the old rule, whatever else is true.
    func testAClippedLampKeepsTheOldRuleExactly() throws {
        let f = negative(clipHoles: true, base: clippedRollBase)
        let reading = Calibrator.rebateReading(f)
        XCTAssertEqual(reading.path, .capRule)
        let old = try XCTUnwrap(Calibrator.clippedLampEstimate(f))
        XCTAssertEqual(try XCTUnwrap(reading.estimate), old, "bit for bit the old rule")
        assertBase(old, "and the old rule is right when the lamp clips", base: clippedRollBase)
    }

    /// Arista 400's case: unclipped holes, but a rebate thin enough that the old rule reads
    /// it. The old rule's answer stands, bit for bit.
    func testUnclippedHolesKeepTheOldRuleWhereItAlreadyReadTheRebate() throws {
        let f = negative(base: clippedRollBase)
        let reading = Calibrator.rebateReading(f)
        XCTAssertEqual(reading.path, .capRule)
        XCTAssertEqual(try XCTUnwrap(reading.estimate), try XCTUnwrap(Calibrator.clippedLampEstimate(f)))
        assertBase(reading.estimate, "the old rule read the rebate", base: clippedRollBase)
    }

    /// A few hot pixels from one bright hole do not make a clipped lamp. The May Azure scans
    /// carry up to 0.5 percent and still read the lamp under the old rule.
    func testASliverOfClippedPixelsStillFindsTheHoles() {
        let reading = Calibrator.rebateReading(negative(lamp: 64000, falloff: 0.1, hotPixels: 100))
        XCTAssertEqual(reading.path, .belowHoles)
        assertBase(reading.estimate, "hot pixels are hole light and go with the holes")
    }

    /// A bright band that is not periodic is not sprocket holes (a light leak along the
    /// edge). The below-holes rule does not take it, the old rule's reading is refused
    /// because a strip reading needs sprocket holes behind it (`stripsShowSprocketHoles`),
    /// and the rebate band route does not take it either, because the level walking inward
    /// from the frame edge does not step down to the picture inside the strip.
    func testABandThatIsNotPeriodicIsRefused() {
        let f = negative(holes: false)
        XCTAssertEqual(Calibrator.stripReading(f).path, .capRule, "the old rule still answers first")
        let reading = Calibrator.rebateReading(f)
        XCTAssertEqual(reading.path, .noSprocketHoles)
        XCTAssertNil(reading.estimate)
        XCTAssertNil(Calibrator.rebateBand(f))
    }

    // MARK: the rebate band, a film edge with no sprocket holes (2026-09-23)

    /// A strip whose outer 16 rows are film base and whose remaining rows are picture: 120
    /// film, or 35 mm cropped past the holes. The base falls off by `falloff` across the
    /// width, and every 200 columns a 12 column run of edge print sits 30 percent under it.
    func holeLessEdge(falloff: Double = 0.2, bandRows: Int = 16) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        let yTop = Int((Double(h) * Calibrator.rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - Calibrator.rebateMargin)).rounded(.up))
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let fromEdge = y < yTop ? y : (y >= yBot ? h - 1 - y : Int.max)
                if fromEdge < bandRows {
                    let k = (1 - falloff * Double(x) / Double(w)) * (x % 200 < 12 ? 0.7 : 1)
                    for c in 0..<3 { px[i + c] = UInt16(Double(base[c]) * k) }
                } else {
                    for c in 0..<3 { px[i + c] = picture[c] }
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// The hole-less edge is refused as holes and read as a band, at the painted base pair.
    func testAHoleLessRebateBandIsRead() throws {
        let f = holeLessEdge()
        XCTAssertFalse(Calibrator.stripsShowSprocketHoles(f, baseGreen: Double(base[1])), "no holes in the fixture")
        let reading = Calibrator.rebateReading(f)
        XCTAssertEqual(reading.path, .rebateBand)
        let e = try XCTUnwrap(reading.estimate)
        XCTAssertEqual(e[0] / e[1], Double(base[0]) / Double(base[1]), accuracy: 0.002)
        XCTAssertEqual(e[2] / e[1], Double(base[2]) / Double(base[1]), accuracy: 0.002)
        XCTAssertEqual(Calibrator.rebateEstimate(f)?[1], e[1])
    }

    /// A strip of picture with no step: the level holds from the frame edge all the way into
    /// the frame, so there is no band ending at a picture, and the frame is refused even
    /// though the strip rule reads a cluster there.
    func testAPictureStripWithNoStepIsRefused() {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let g = 20000 * (1 - 0.15 * Double(x) / Double(w)) * (1 - 0.03 * Double(y) / Double(h))
                px[i] = UInt16(g * 0.6); px[i + 1] = UInt16(g); px[i + 2] = UInt16(g * 0.8)
            }
        }
        let f = DecodedFrame(width: w, height: h, pixels: px)
        XCTAssertNotNil(Calibrator.stripReading(f).estimate, "the fixture must fool the strip rule, or this tests nothing")
        XCTAssertNil(Calibrator.rebateBand(f))
        let reading = Calibrator.rebateReading(f)
        XCTAssertNil(reading.estimate)
        XCTAssertEqual(reading.path, .noSprocketHoles)
    }

    /// The same hole-less edge with the band cut to fewer rows than the width fit takes is
    /// not a band: the outer rows must all be rebate.
    func testABandThinnerThanTheOuterRowsIsRefused() {
        XCTAssertNil(Calibrator.rebateBand(holeLessEdge(bandRows: 4)))
        XCTAssertNotNil(Calibrator.rebateBand(holeLessEdge(bandRows: 10)))
    }

    /// Holes at a pitch no 35 mm frame has (here a twentieth of the width, like edge print)
    /// are not taken for sprocket holes.
    func testAnImplausiblePitchKeepsTheOldRule() {
        var px = negative().pixels
        let yTop = Int((Double(h) * Calibrator.rebateMargin).rounded(.down))
        let yBot = Int((Double(h) * (1 - Calibrator.rebateMargin)).rounded(.up))
        for y in 0..<h where y < yTop || y >= yBot {
            let ys = y < yTop ? y : y - yBot
            for x in 0..<w {
                let i = (y * w + x) * 3
                let hole = holeRows.contains(ys) && x % 64 >= 20 && x % 64 < 44
                let v: [UInt16] = hole ? [21000, 40000, 27000] : base
                for c in 0..<3 { px[i + c] = v[c] }
            }
        }
        let f = DecodedFrame(width: w, height: h, pixels: px)
        XCTAssertEqual(Calibrator.rebateReading(f).path, .capRule)
    }

    func testPeriodicityNeedsFourEvenlySpacedRuns() {
        func share(_ starts: [Int], width: Int = 6, count: Int = 200) -> [Double] {
            var s = [Double](repeating: 0, count: count)
            for x0 in starts { for x in x0..<min(count, x0 + width) { s[x] = 0.5 } }
            return s
        }
        XCTAssertEqual(Calibrator.holePitch(share([10, 42, 74, 106, 138])), 32)
        XCTAssertNil(Calibrator.holePitch(share([10, 42, 74])), "three runs is not enough")
        XCTAssertNil(Calibrator.holePitch(share([10, 30, 90, 100, 170])), "uneven spacing")
        XCTAssertNotNil(Calibrator.holePitch(share([0, 100, 132, 164, 196]).enumerated().map { $0.offset < 60 ? 0.9 : $0.element }),
                        "a wide bare-lamp region beside the holes is set aside")
    }

    // MARK: the eyedropper

    /// A click on the rebate between two holes: the square takes in a hole and its edge and a
    /// slice of the strip beyond, and still reads the base exactly.
    func testAPickBetweenUnclippedHolesReadsTheBase() {
        let f = negative()
        let point = CGPoint(x: (Double(pitch) * 3 + 8) / Double(w), y: 18 / Double(h))
        assertBase(Calibrator.patchEstimate(f, at: point, radius: 0.04), "the rebate between the holes")
    }

    func testAPickOnThePictureOfAnUnclippedFrameIsNil() {
        let f = negative()
        XCTAssertNil(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: 0.02),
                     "nothing near the rebate's green is left")
    }

    /// With a clipped lamp the patch is the old rule: holes go by the clip guard, and a pick
    /// on the picture still reads the picture.
    func testAClippedFrameKeepsTheOldPatch() throws {
        let f = negative(clipHoles: true, base: clippedRollBase)
        let point = CGPoint(x: (Double(pitch) * 3 + 14) / Double(w), y: 18 / Double(h))
        assertBase(Calibrator.patchEstimate(f, at: point, radius: 0.015), "the clip guard drops the holes",
                   base: clippedRollBase)
        let onPicture = try XCTUnwrap(Calibrator.patchEstimate(f, at: CGPoint(x: 0.5, y: 0.5), radius: 0.02))
        XCTAssertEqual(onPicture, picture.map(Double.init), "the old patch reads whatever it was aimed at")
    }
}

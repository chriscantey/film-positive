import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The geometry contract: straighten, then crop in original coordinates, then rotate, then
/// flip. A crop drawn on the proxy names the same film on the full decode, a zero angle
/// changes no pixel, and the point arithmetic agrees with the resampler.
final class GeometryTests: XCTestCase {
    let fixtures = FixtureFrames()

    /// A synthetic 16-bit frame: dark ground with one bright rectangle whose left edge is
    /// tilted by `tiltDegrees` (clockwise on screen), so a straighten by -tilt squares it.
    func tilted(width w: Int, height h: Int, tiltDegrees: Double) -> DecodedFrame {
        var px = [UInt16](repeating: 4000, count: w * h * 3)
        let t = tiltDegrees * Double.pi / 180
        let cx = Double(w) / 2, cy = Double(h) / 2
        for y in 0..<h {
            for x in 0..<w {
                // rotate the pixel center back by -tilt and test against an axis-aligned box
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let rx = dx * cos(-t) - dy * sin(-t), ry = dx * sin(-t) + dy * cos(-t)
                if abs(rx) < Double(w) * 0.3 && abs(ry) < Double(h) * 0.3 {
                    let i = (y * w + x) * 3; px[i] = 60000; px[i + 1] = 60000; px[i + 2] = 60000
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// Column of the bright box's left edge on row `y`, the first pixel above half scale.
    func leftEdge(_ f: DecodedFrame, row y: Int) -> Int? {
        for x in 0..<f.width where f.pixels[(y * f.width + x) * 3] > 32000 { return x }
        return nil
    }

    func testStraightenSquaresATiltedEdge() {
        let f = tilted(width: 1200, height: 800, tiltDegrees: 2.5)
        let before = (200..<600).compactMap { leftEdge(f, row: $0) }
        XCTAssertGreaterThan(before.max()! - before.min()!, 10, "the synthetic edge is tilted")
        let s = Straighten.apply(f, degrees: -2.5, crop: nil)
        XCTAssertEqual(s.width, f.width); XCTAssertEqual(s.height, f.height)
        let after = (200..<600).compactMap { leftEdge(s, row: $0) }
        XCTAssertLessThanOrEqual(after.max()! - after.min()!, 1, "straightened edge is vertical within a pixel")
        // and the other way round leans it further, so the sign convention is real
        let worse = Straighten.apply(f, degrees: 2.5, crop: nil)
        let w2 = (200..<600).compactMap { leftEdge(worse, row: $0) }
        XCTAssertGreaterThan(w2.max()! - w2.min()!, before.max()! - before.min()!)
    }

    func testZeroAngleIsBitIdenticalAndCropOnly() {
        let f = tilted(width: 640, height: 480, tiltDegrees: 1)
        XCTAssertEqual(Straighten.apply(f, degrees: 0, crop: nil).pixels, f.pixels)
        XCTAssertEqual(Straighten.apply(f, degrees: 0.004, crop: nil).pixels, f.pixels, "below the negligible threshold")
        let c = Straighten.apply(f, degrees: 0, crop: CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))
        XCTAssertEqual(c.width, 320); XCTAssertEqual(c.height, 240)
        XCTAssertEqual(c.pixels[0..<3], f.pixels[((120 * 640) + 160) * 3..<((120 * 640) + 160) * 3 + 3])
    }

    // The crop rect and angle stored in original coordinates give the same film on
    // the proxy and on the full decode, within one pixel
    func testCropSurvivesResolutionWithinOnePixel() throws {
        let f = try FixtureFrames.first()
        let inp = try fixtures.input(for: f)
        let full = try fixtures.decoded(f)
        let half = try RawDecoder(halfSize: true).decode(f.cr2)
        let g = GeometrySettings(rotate: 0, flip: false, straightenDegrees: 0.35, crop: CropRect(x: 0.1, y: 0.15, w: 0.7, h: 0.6))
        func developed(_ d: DecodedFrame) -> DecodedFrame {
            let (an, _) = DevelopMath.analyze(d, input: inp)
            return DevelopTables(analysis: an, mono: inp.mono).apply(d, flip: false)
        }
        let outFull = Geometry.apply(developed(full), g)
        let outHalf = Geometry.apply(developed(half), g)
        XCTAssertEqual(outFull.width, Int((0.7 * Double(full.width)).rounded()), accuracy: 1)
        XCTAssertEqual(outFull.height, Int((0.6 * Double(full.height)).rounded()), accuracy: 1)
        XCTAssertEqual(outHalf.width * 2, outFull.width, accuracy: 2)
        XCTAssertEqual(outHalf.height * 2, outFull.height, accuracy: 2)
        // content: the full render halved should match the proxy render closely; a one
        // pixel registration error would show as a large mean difference on film grain
        let halved = Geometry.halve(outFull)
        var sum = 0.0; var n = 0
        let w = min(halved.width, outHalf.width), h = min(halved.height, outHalf.height)
        for y in stride(from: 0, to: h, by: 7) {
            for x in stride(from: 0, to: w, by: 7) {
                for c in 0..<3 {
                    sum += abs(Double(halved.pixels[(y * halved.width + x) * 3 + c]) - Double(outHalf.pixels[(y * outHalf.width + x) * 3 + c]))
                    n += 1
                }
            }
        }
        let mean = sum / Double(n) / 65535
        print(String(format: "proxy vs halved full after straighten+crop: mean |d| %.4f of full scale", mean))
        XCTAssertLessThan(mean, 0.02)
    }

    func testFineRotationAgreesWithTheResampler() {
        // A bright dot placed at a known point, straightened by 3 degrees: the ported point
        // mapping must say where it landed, and the resampled frame must have it there.
        let w = 900, h = 600
        var px = [UInt16](repeating: 1000, count: w * h * 3)
        let src = CGPoint(x: 0.7, y: 0.3)
        let sx = Int(src.x * Double(w)), sy = Int(src.y * Double(h))
        for dy in -2...2 { for dx in -2...2 { let i = ((sy + dy) * w + sx + dx) * 3; px[i] = 65000; px[i + 1] = 65000; px[i + 2] = 65000 } }
        let f = DecodedFrame(width: w, height: h, pixels: px)
        let deg = 3.0
        let s = Straighten.apply(f, degrees: deg, crop: nil)
        let dst = FineRotation.straightened(src, byDegrees: deg, aspect: CGFloat(w) / CGFloat(h))
        var bestX = 0, bestY = 0, best: UInt16 = 0
        for y in 0..<h { for x in 0..<w { let v = s.pixels[(y * w + x) * 3]; if v > best { best = v; bestX = x; bestY = y } } }
        XCTAssertEqual(Double(bestX) + 0.5, dst.x * Double(w), accuracy: 3.0)
        XCTAssertEqual(Double(bestY) + 0.5, dst.y * Double(h), accuracy: 3.0)
        let back = FineRotation.unstraightened(dst, byDegrees: deg, aspect: CGFloat(w) / CGFloat(h))
        XCTAssertEqual(back.x, src.x, accuracy: 1e-9); XCTAssertEqual(back.y, src.y, accuracy: 1e-9)
    }

    func testQuarterTurnMappingsInvert() {
        for t in QuarterTurn.allCases {
            let p = CGPoint(x: 0.2, y: 0.7)
            let q = t.originalPoint(fromDisplay: t.displayPoint(fromOriginal: p))
            XCTAssertEqual(q.x, p.x, accuracy: 1e-12); XCTAssertEqual(q.y, p.y, accuracy: 1e-12)
            let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
            let rr = t.originalRect(fromDisplay: t.displayRect(fromOriginal: r))
            XCTAssertEqual(rr.minX, r.minX, accuracy: 1e-12); XCTAssertEqual(rr.height, r.height, accuracy: 1e-12)
        }
        XCTAssertEqual(QuarterTurn.cw90.displayPoint(fromOriginal: CGPoint(x: 0, y: 0)), CGPoint(x: 1, y: 0))
        XCTAssertEqual(QuarterTurn(degrees: 450), .cw90)
    }

    func testCropDetectorFindsTheNegativeOnASyntheticStand() {
        // dark mask with a bright negative in the middle, plus dust specks on the mask
        let w = 1000, h = 700
        var px = [UInt16](repeating: 2000, count: w * h * 3)
        for y in 140..<560 { for x in 200..<800 { let i = (y * w + x) * 3; px[i] = 40000; px[i + 1] = 40000; px[i + 2] = 40000 } }
        for (x, y) in [(50, 50), (950, 650), (100, 600)] { let i = (y * w + x) * 3; px[i] = 60000; px[i + 1] = 60000; px[i + 2] = 60000 }
        let r = CropDetector.detect(in: DecodedFrame(width: w, height: h, pixels: px))
        let res = try! XCTUnwrap(r)
        XCTAssertTrue(res.isFullyBounded)
        XCTAssertEqual(res.rect.minX, 0.2, accuracy: 0.01); XCTAssertEqual(res.rect.maxX, 0.8, accuracy: 0.01)
        XCTAssertEqual(res.rect.minY, 0.2, accuracy: 0.01); XCTAssertEqual(res.rect.maxY, 0.8, accuracy: 0.01)
        // an empty stand: nothing convincing
        XCTAssertNil(CropDetector.detect(in: DecodedFrame(width: 400, height: 300, pixels: [UInt16](repeating: 3000, count: 400 * 300 * 3))))
    }

    func testCropBoxArithmetic() {
        let r = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let d = CropBox.dragged(r, handle: .left, by: CGSize(width: 0.9, height: 0))
        XCTAssertEqual(d.minX, 0.7 - CropBox.minSize, accuracy: 1e-12, "a side cannot cross its opposite")
        XCTAssertEqual(CropBox.moved(r, by: CGSize(width: 1, height: 1)), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(CropBox.handle(at: CGPoint(x: 0.2, y: 0.2), in: r, tolerance: CGSize(width: 0.01, height: 0.01)), .topLeft)
        XCTAssertEqual(CropBox.zone(at: CGPoint(x: 0.45, y: 0.45), in: r, tolerance: CGSize(width: 0.01, height: 0.01), rotateBand: CGSize(width: 0.03, height: 0.03)), .move)
    }
}

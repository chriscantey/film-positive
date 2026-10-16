import XCTest
import CoreGraphics
@testable import FilmPositiveCore

/// Film Tether's `FrameFinderTests`, ported alongside the detector.
///
/// The tests come with the port on purpose. `FrameFinder` is the detector Tether's autocrop
/// actually uses, and every threshold in it was measured on a real copy stand, so the
/// only way to know the port preserved the behavior rather than merely the text is to run
/// the same cases against it. The one change is the picture builder: Tether draws into a
/// `CGContext` and hands over a `CGImage`, while this port samples a `DecodedFrame`, so the
/// synthetic film is written straight into 16-bit pixels instead.
final class FrameFinderTests: XCTestCase {

    /// Deterministic noise, so a failure is always the same failure.
    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
        }
    }

    private let width = 768
    private let height = 576

    /// A picture of film: a flat field at `bandLevel` standing in for unexposed film, with
    /// textured rectangles standing in for exposed frames. Rects are normalized y-UP, as in
    /// Tether's version, so the cases transfer unchanged.
    ///
    /// The texture is blocky rather than per-pixel because the detector downsamples to 192
    /// wide before measuring: per-pixel noise would average straight out, which is exactly
    /// what it is meant to do to grain and dust.
    private func makeFilm(
        frames: [CGRect],
        bandLevel: Double = 0.80,
        pictureLevel: Double = 0.35,
        pictureSpread: Double = 0.30,
        block: Int = 16,
        smoothPatch: Double = 0,
        seed: UInt64 = 42
    ) -> DecodedFrame {
        var v = [Double](repeating: bandLevel, count: width * height)
        var rng = Rand(state: seed)
        for (n, frame) in frames.enumerated() {
            let x0 = Int((frame.minX * Double(width)).rounded())
            let x1 = Int((frame.maxX * Double(width)).rounded())
            // y-up rect to y-down pixels.
            let y0 = Int(((1 - frame.maxY) * Double(height)).rounded())
            let y1 = Int(((1 - frame.minY) * Double(height)).rounded())
            var y = y0
            while y < y1 {
                var x = x0
                // Distance from the frame's own top edge, y-down, 0...1.
                let fromTop = 1 - (Double(y + block / 2) - Double(y0)) / max(Double(y1 - y0), 1)
                while x < x1 {
                    var value = pictureLevel + (rng.next() - 0.5) * pictureSpread
                    if n == 0, smoothPatch > 0, fromTop < smoothPatch {
                        // Ramp texture out and level up toward the band with no step
                        // anywhere: the shape that fooled a smoothness test on a real
                        // negative.
                        let t = 1 - fromTop / smoothPatch
                        value = pictureLevel + (bandLevel - pictureLevel) * 0.45 * t
                            + (rng.next() - 0.5) * pictureSpread * (1 - t)
                    }
                    for py in y..<min(y + block, y1) where py >= 0 && py < height {
                        for px in x..<min(x + block, x1) where px >= 0 && px < width {
                            v[py * width + px] = value
                        }
                    }
                    x += block
                }
                y += block
            }
        }
        return frame(from: v)
    }

    private func frame(from v: [Double]) -> DecodedFrame {
        var pixels = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let q = UInt16(min(max(v[i], 0), 1) * 65_535)
            pixels[i * 3] = q; pixels[i * 3 + 1] = q; pixels[i * 3 + 2] = q
        }
        return DecodedFrame(width: width, height: height, pixels: pixels)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.03,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: a single sheet

    func testFindsOneFrameSurroundedByUnexposedFilm() throws {
        let f = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let r = try XCTUnwrap(FrameFinder.detect(in: makeFilm(frames: [f])))
        assertRect(r.rect, f)
        XCTAssertTrue(r.isFullyBounded)
    }

    /// The unexposed band is DENSE, so it reads dark against a bright picture. Nothing may
    /// assume the band is the brighter side. This is the case that matters most for this
    /// port: Film Tether autocrops a negative, where the rebate is clear, and Film Positive
    /// autocrops a developed POSITIVE, where it is dark. Same detector, opposite polarity.
    func testFindsAFrameWhenTheUnexposedBandIsDark() throws {
        let f = CGRect(x: 0.22, y: 0.25, width: 0.55, height: 0.50)
        let r = try XCTUnwrap(FrameFinder.detect(in: makeFilm(frames: [f], bandLevel: 0.06, pictureLevel: 0.62)))
        assertRect(r.rect, f)
        XCTAssertTrue(r.isFullyBounded)
    }

    // MARK: a strip

    /// The point of searching outward from the center: with three frames in view a bounding
    /// box of everything that is not background spans all three. Only the one under the
    /// lens is wanted. This is precisely what `CropDetector` cannot do.
    func testPicksTheMiddleFrameOfAStrip() throws {
        let frames = [
            CGRect(x: 0.02, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.36, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.70, y: 0.20, width: 0.28, height: 0.60),
        ]
        let r = try XCTUnwrap(FrameFinder.detect(in: makeFilm(frames: frames)))
        assertRect(r.rect, frames[1])
    }

    func testStartingPointSelectsWhichFrameIsFound() throws {
        let frames = [
            CGRect(x: 0.02, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.36, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.70, y: 0.20, width: 0.28, height: 0.60),
        ]
        let img = makeFilm(frames: frames)
        let left = try XCTUnwrap(FrameFinder.detect(in: img, around: CGPoint(x: 0.16, y: 0.5)))
        assertRect(left.rect, frames[0])
        let right = try XCTUnwrap(FrameFinder.detect(in: img, around: CGPoint(x: 0.84, y: 0.5)))
        assertRect(right.rect, frames[2])
    }

    // MARK: running off the picture

    func testReportsSidesWhereTheFilmRunsOffThePicture() throws {
        let f = CGRect(x: -0.20, y: 0.20, width: 0.75, height: 0.60)
        let r = try XCTUnwrap(FrameFinder.detect(in: makeFilm(frames: [f])))
        XCTAssertEqual(r.unboundedEdges, [.left])
        XCTAssertFalse(r.isFullyBounded)
        XCTAssertEqual(r.rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.rect.maxX, 0.55, accuracy: 0.03)
    }

    /// A negative filling the whole picture has no edges to find. Returning the whole frame
    /// dressed up as a detection would be worse than admitting it.
    func testRefusesWhenNoEdgeIsVisibleAtAll() throws {
        XCTAssertNil(FrameFinder.detect(in: makeFilm(frames: [CGRect(x: -0.1, y: -0.1, width: 1.2, height: 1.2)])))
    }

    // MARK: not being fooled

    /// The failure a real negative produced: a smooth bright region INSIDE the photograph
    /// passed both the smoothness and the level test and cut the frame short by an eighth of
    /// its height. What separates it from a real edge is that exposed and unexposed film
    /// meet at a step while a featureless part of a picture blends into its surroundings.
    func testASmoothBrightRegionInsideThePictureIsNotAnEdge() throws {
        let f = CGRect(x: 0.20, y: 0.15, width: 0.60, height: 0.70)
        let r = try XCTUnwrap(FrameFinder.detect(in: makeFilm(frames: [f], smoothPatch: 0.35)))
        XCTAssertEqual(r.rect.minY, f.minY, accuracy: 0.04,
                       "stopped at the smooth patch instead of the frame's edge")
        assertRect(r.rect, f, accuracy: 0.04)
    }

    /// One stray smooth line, a scratch or an artifact, is not a boundary.
    func testASingleSmoothLineDoesNotEndTheFrame() throws {
        let f = CGRect(x: 0.20, y: 0.15, width: 0.60, height: 0.70)
        var v = [Double](repeating: 0.80, count: width * height)
        let base = makeFilm(frames: [f])
        for i in 0..<(width * height) { v[i] = Double(base.pixels[i * 3]) / 65_535 }
        // One scratch across the middle of the frame, two rows tall.
        let y = Int(Double(height) * 0.45)
        for py in y..<(y + 2) {
            for px in Int(0.20 * Double(width))..<Int(0.80 * Double(width)) { v[py * width + px] = 0.8 }
        }
        let r = try XCTUnwrap(FrameFinder.detect(in: frame(from: v)))
        assertRect(r.rect, f, accuracy: 0.04)
    }

    // MARK: margin

    func testMarginGrowsTheCropAndStaysInThePicture() throws {
        let f = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let img = makeFilm(frames: [f])
        let tight = try XCTUnwrap(FrameFinder.detect(in: img))
        let loose = try XCTUnwrap(FrameFinder.detect(in: img, marginFraction: 0.02))
        XCTAssertGreaterThan(loose.rect.width, tight.rect.width)
        XCTAssertGreaterThan(loose.rect.height, tight.rect.height)
        XCTAssertGreaterThanOrEqual(loose.rect.minX, 0)
        XCTAssertGreaterThanOrEqual(loose.rect.minY, 0)
        XCTAssertLessThanOrEqual(loose.rect.maxX, 1)
        XCTAssertLessThanOrEqual(loose.rect.maxY, 1)
    }

    // MARK: reported film base

    func testReportsTheLevelOfTheUnexposedFilm() throws {
        let f = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let r = try XCTUnwrap(FrameFinder.detect(in: makeFilm(frames: [f], bandLevel: 0.80)))
        let level = try XCTUnwrap(r.filmBaseLevel)
        XCTAssertEqual(level, 0.80, accuracy: 0.06)
    }
}

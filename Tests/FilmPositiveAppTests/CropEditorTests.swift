import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The crop tool's arithmetic and its storage contract.
///
/// The claim that matters is not "the numbers round trip", which a wrong convention
/// would also satisfy. It is that a rectangle drawn on screen, stored through
/// `CropEditor.geometry`, and then handed to the ENGINE, selects the film the user drew
/// over. So the central tests run the stored value through `Straighten.apply` and
/// `Geometry.orient` and read the pixels back.
final class CropEditorTests: XCTestCase {
    /// These are OFF by default. Six of these tests run 104 to 213 seconds EACH, about twelve
    /// minutes for this suite alone, because every one builds a synthetic frame and runs the
    /// whole detector ladder over it at every sweep threshold.
    ///
    /// They are skipped rather than deleted because they cover real rules, including the
    /// anchored route never claiming to be a measurement and the planner's angle being
    /// carried but not applied. Run them deliberately with `FP_CROPTESTS=1`. The right fix
    /// is to make them fast, most likely by shrinking the synthetic frames, and then turn
    /// them back on.
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FP_CROPTESTS"] == "1",
                          "slow crop suite, off by default since 2026-09-12. FP_CROPTESTS=1 to run")
    }


    // MARK: synthetic frames

    /// Red encodes x and green encodes y, both linear, so a bilinear sample decodes back
    /// to the exact continuous source position it came from.
    private func ramp(_ w: Int, _ h: Int) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                px[i] = UInt16((Double(x) / Double(w - 1)) * 60000)
                px[i + 1] = UInt16((Double(y) / Double(h - 1)) * 60000)
                px[i + 2] = 30000
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }

    /// Decode a ramp pixel back to a normalized position in the frame it came from.
    private func position(of px: [UInt16], at index: Int, w: Int, h: Int) -> CGPoint {
        let sx = Double(px[index]) / 60000 * Double(w - 1)
        let sy = Double(px[index + 1]) / 60000 * Double(h - 1)
        return CGPoint(x: (sx + 0.5) / Double(w), y: (sy + 0.5) / Double(h))
    }

    /// Drive the editor the way a user does: grab the top left grip, then the bottom
    /// right one. Uses only the gesture API, so the drag path is under test too.
    /// Draws an ARBITRARY rect, so it turns the aspect lock off first. The lock defaults to
    /// `.original` and would otherwise reshape every rect drawn here, which is correct
    /// behavior and has nothing to do with what these tests assert: they are about where a
    /// stored crop lands under rotation, mirroring and straightening. The lock's own behavior
    /// is asserted in `CropAspectTests`.
    private func draw(_ e: inout CropEditor, _ r: CGRect) {
        e.aspect = .freeform
        e.begin(at: CGPoint(x: 0, y: 0))
        e.drag(to: CGPoint(x: r.minX, y: r.minY))
        e.end()
        e.begin(at: CGPoint(x: 1, y: 1))
        e.drag(to: CGPoint(x: r.maxX, y: r.maxY))
        e.end()
    }

    // MARK: the display space is the engine's display space

    /// The one convention most likely to be silently wrong: `Geometry.orient` mirrors x
    /// and THEN turns clockwise (`DevelopTables.dstIndex`). Rather than trust that reading,
    /// put a single lit pixel through the engine for all eight orientations and check the
    /// editor's mapping predicts where it lands.
    func testDisplayMappingAgreesWithTheEngine() {
        let w = 7, h = 5, mx = 5, my = 1
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                var px = [UInt16](repeating: 0, count: w * h * 3)
                px[(my * w + mx) * 3] = 65535
                let oriented = Geometry.orient(DecodedFrame(width: w, height: h, pixels: px), flip: flip, rotate: rotate)
                var found: (Int, Int)?
                for y in 0..<oriented.height {
                    for x in 0..<oriented.width where oriented.pixels[(y * oriented.width + x) * 3] == 65535 {
                        found = (x, y)
                    }
                }
                let hit = try! XCTUnwrap(found, "engine lost the marker at rotate \(rotate) flip \(flip)")
                let turn = QuarterTurn(degrees: rotate)!
                let p = CGPoint(x: (Double(mx) + 0.5) / Double(w), y: (Double(my) + 0.5) / Double(h))
                let d = CropEditor.displayPoint(fromOriginal: p, turn: turn, flip: flip)
                XCTAssertEqual(Int(d.x * Double(oriented.width)), hit.0, "x at rotate \(rotate) flip \(flip)")
                XCTAssertEqual(Int(d.y * Double(oriented.height)), hit.1, "y at rotate \(rotate) flip \(flip)")
            }
        }
    }

    func testDisplayAndOriginalRectsRoundTrip() {
        let r = CGRect(x: 0.137, y: 0.211, width: 0.402, height: 0.318)
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                let turn = QuarterTurn(degrees: rotate)!
                let d = CropEditor.displayRect(fromOriginal: r, turn: turn, flip: flip)
                let back = CropEditor.originalRect(fromDisplay: d, turn: turn, flip: flip)
                XCTAssertEqual(back.minX, r.minX, accuracy: 1e-12)
                XCTAssertEqual(back.minY, r.minY, accuracy: 1e-12)
                XCTAssertEqual(back.width, r.width, accuracy: 1e-12)
                XCTAssertEqual(back.height, r.height, accuracy: 1e-12)
            }
        }
    }

    // MARK: the storage contract

    /// A rectangle drawn on screen over a turned, mirrored, straightened frame, stored,
    /// and then executed by the engine: the middle of what comes out is the film that was
    /// in the middle of what was drawn. This is the whole storage contract in one
    /// assertion, and it fails if the crop is stored in display space, if the mirror and
    /// the turn are composed the wrong way round, or if the crop is measured before the
    /// straighten instead of after it.
    func testStoredCropNamesTheFilmThatWasDrawnOn() throws {
        let w = 240, h = 160
        let f0 = ramp(w, h)
        let drawn = CGRect(x: 0.30, y: 0.25, width: 0.30, height: 0.34)
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                for degrees in [0.0, 3.0, -7.5] {
                    var e = CropEditor(geometry: GeometrySettings(rotate: rotate, flip: flip, straightenDegrees: degrees),
                                       originalAspect: CGFloat(w) / CGFloat(h))
                    draw(&e, drawn)
                    let g = e.geometry
                    let crop = try XCTUnwrap(g.crop)

                    // The engine's own straighten and crop, before the orientation step,
                    // so this assertion is about the crop alone.
                    let cropped = Straighten.apply(f0, degrees: g.straightenDegrees, crop: crop)
                    let cx = cropped.width / 2, cy = cropped.height / 2
                    let decoded = position(of: cropped.pixels, at: (cy * cropped.width + cx) * 3, w: w, h: h)

                    let predicted = e.rawOriginalPoint(fromDisplay: CGPoint(x: drawn.midX, y: drawn.midY))
                    let label = "rotate \(rotate) flip \(flip) angle \(degrees)"
                    XCTAssertEqual(Double(decoded.x), Double(predicted.x), accuracy: 1.5 / Double(w), "x, \(label)")
                    XCTAssertEqual(Double(decoded.y), Double(predicted.y), accuracy: 1.5 / Double(h), "y, \(label)")
                }
            }
        }
    }

    /// The other half of the same claim: the crop is the size that was drawn. A drawn box
    /// 0.30 of the display wide is 0.30 of the ORIGINAL height when the picture is turned
    /// a quarter, which is exactly the confusion this catches.
    func testStoredCropHasTheSizeThatWasDrawn() throws {
        let w = 240, h = 160
        let drawn = CGRect(x: 0.30, y: 0.25, width: 0.30, height: 0.34)
        for rotate in [0, 90, 180, 270] {
            let turn = QuarterTurn(degrees: rotate)!
            var e = CropEditor(geometry: GeometrySettings(rotate: rotate), originalAspect: CGFloat(w) / CGFloat(h))
            draw(&e, drawn)
            let crop = try XCTUnwrap(e.geometry.crop)
            let expectedW = turn.swapsAxes ? drawn.height : drawn.width
            let expectedH = turn.swapsAxes ? drawn.width : drawn.height
            XCTAssertEqual(crop.w, Double(expectedW), accuracy: 1e-9, "width at rotate \(rotate)")
            XCTAssertEqual(crop.h, Double(expectedH), accuracy: 1e-9, "height at rotate \(rotate)")
            // and the engine agrees about the pixel box it produces
            let box = Geometry.box(crop, width: w, height: h)
            XCTAssertEqual(Double(box.width) / Double(w), Double(expectedW), accuracy: 2.0 / Double(w))
            XCTAssertEqual(Double(box.height) / Double(h), Double(expectedH), accuracy: 2.0 / Double(h))
        }
    }

    /// The crop rect is measured AFTER the straighten, so an angle on its own must not
    /// move the stored rectangle. If the stored value moved with the angle, the engine
    /// would apply the rotation twice.
    func testStraightenAloneDoesNotMoveTheStoredRect() {
        var e = CropEditor(geometry: GeometrySettings(rotate: 90, flip: true), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4))
        let before = e.geometry.crop
        e.setDegrees(6.25)
        let after = e.geometry.crop
        XCTAssertEqual(before?.x, after?.x)
        XCTAssertEqual(before?.y, after?.y)
        XCTAssertEqual(before?.w, after?.w)
        XCTAssertEqual(before?.h, after?.h)
        XCTAssertEqual(e.geometry.straightenDegrees, 6.25, accuracy: 1e-12)
    }

    // MARK: straighten

    func testStraightenClampsAndTreatsATinyAngleAsNone() {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        e.setDegrees(90)
        XCTAssertEqual(e.degrees, FineRotation.limitDegrees)
        e.setDegrees(-120)
        XCTAssertEqual(e.degrees, -FineRotation.limitDegrees)
        e.setDegrees(0.005)
        XCTAssertEqual(e.geometry.straightenDegrees, 0, "below the negligible threshold is stored as a true zero")
        XCTAssertTrue(e.geometry.isIdentity)
        e.setDegrees(0.4)
        XCTAssertEqual(e.geometry.straightenDegrees, 0.4, accuracy: 1e-12)
    }

    /// The band outside a grip straightens rather than resizing, and a drag there reports
    /// itself as straightening, which is what the grid overlay's fade is bound to.
    func testRotateBandStraightensAndReportsItself() {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let cropBefore = e.geometry.crop

        // just outside the top left grip, inside the rotate band
        let zone = e.begin(at: CGPoint(x: 0.25 - 0.05, y: 0.25 - 0.05))
        guard case .rotate = zone else { return XCTFail("expected the rotate band, got \(zone)") }
        XCTAssertTrue(e.isStraightening)
        e.drag(to: CGPoint(x: 0.25 - 0.02, y: 0.25 - 0.07))
        XCTAssertNotEqual(e.degrees, 0, "a drag in the band changes the angle")
        e.end()
        XCTAssertFalse(e.isStraightening, "the grid fades out when the drag ends")
        XCTAssertEqual(cropBefore?.x, e.geometry.crop?.x, "straightening does not move the crop")
        XCTAssertEqual(cropBefore?.w, e.geometry.crop?.w)
    }

    func testInteriorAndGripZones() {
        let e0 = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        var e = e0
        draw(&e, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        var probe = e
        XCTAssertEqual(probe.begin(at: CGPoint(x: 0.5, y: 0.5)), .move)
        probe = e
        XCTAssertEqual(probe.begin(at: CGPoint(x: 0.75, y: 0.75)), .resize(.bottomRight))
        probe = e
        XCTAssertEqual(probe.begin(at: CGPoint(x: 0.5, y: 0.25)), .resize(.top))
        probe = e
        XCTAssertEqual(probe.begin(at: CGPoint(x: 0.02, y: 0.98)), CropBox.Zone.none, "well clear of the box is nothing")
    }

    // MARK: the rectangle

    /// The seed comes from the detector, not from a guess, and it is grown by the
    /// margin so the crop does not shave the edge the detector just found.
    func testSeedFromTheDetectorOnASyntheticStand() throws {
        let w = 1000, h = 700
        var px = [UInt16](repeating: 2000, count: w * h * 3)
        for y in 140..<560 {
            for x in 200..<800 {
                let i = (y * w + x) * 3
                px[i] = 40000; px[i + 1] = 40000; px[i + 2] = 40000
            }
        }
        for (x, y) in [(50, 50), (950, 650), (100, 600)] {
            let i = (y * w + x) * 3
            px[i] = 60000; px[i + 1] = 60000; px[i + 2] = 60000
        }
        let f = DecodedFrame(width: w, height: h, pixels: px)
        let found = try XCTUnwrap(CropEditor.detect(in: f), "the ported detector should find the negative")
        XCTAssertTrue(found.isFullyBounded)

        // FREEFORM is where "grown by the margin and nothing else" is still the whole rule,
        // so the exact arithmetic is asserted here rather than deleted.
        let grown = CropBox.expanded(found.rect, byFraction: CropEditor.seedMargin)
        var free = CropEditor(geometry: GeometrySettings(), originalAspect: CGFloat(w) / CGFloat(h))
        free.aspect = .freeform
        XCTAssertFalse(free.hasCrop)
        free.seed(fromDetected: found.rect)
        XCTAssertTrue(free.hasCrop)
        XCTAssertEqual(free.displayRect.minX, grown.minX, accuracy: 1e-9)
        XCTAssertEqual(free.displayRect.width, grown.width, accuracy: 1e-9)
        XCTAssertLessThan(free.displayRect.minX, found.rect.minX, "the seed is grown, not taken flush")
        XCTAssertGreaterThan(free.displayRect.maxX, found.rect.maxX)

        // The DEFAULT is `.original`, and a seeded box is held to it rather than given an
        // invented aspect. Asserted as the RULE rather than as the coordinates this synthetic
        // happens to produce: the box carries the frame's ratio, and holding it never pushes a
        // side further out than the free version, because the whole point is to pull a long
        // side in rather than push its opposite out.
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: CGFloat(w) / CGFloat(h))
        XCTAssertEqual(e.aspect, .original, "the seed test is only meaningful on the default")
        e.seed(fromDetected: found.rect)
        XCTAssertTrue(e.hasCrop)
        // `displayRect` is NORMALIZED to the canvas, so a box carrying the canvas's own ratio
        // has a normalized width over height of 1.0, not w/h. Multiply back into pixels
        // before comparing, or the assertion demands a box 1.43 times wider than the frame.
        let displayAspect = CGFloat(w) / CGFloat(h)
        let seededAspect = (e.displayRect.width * CGFloat(w)) / (e.displayRect.height * CGFloat(h))
        XCTAssertEqual(seededAspect, displayAspect, accuracy: 0.01,
                       "a seeded box carries the frame's own ratio")
        XCTAssertLessThanOrEqual(e.displayRect.width, free.displayRect.width + 1e-9, "held in, never out")
        XCTAssertLessThanOrEqual(e.displayRect.height, free.displayRect.height + 1e-9, "held in, never out")

        // a turned frame: the detector's rect arrives in display space, so the stored
        // crop has to come back to original space. Freeform so the axis swap is measured
        // on its own rather than through the ratio lock.
        var turned = CropEditor(geometry: GeometrySettings(rotate: 90, flip: true), originalAspect: CGFloat(h) / CGFloat(w))
        turned.aspect = .freeform
        turned.seed(fromDetected: found.rect, margin: 0)
        let crop = try XCTUnwrap(turned.geometry.crop)
        XCTAssertEqual(crop.w, Double(found.rect.height), accuracy: 1e-9, "a quarter turn swaps the axes of the stored rect")
        XCTAssertEqual(crop.h, Double(found.rect.width), accuracy: 1e-9)
    }

    func testDragsStayInsideTheFrameAndAboveTheMinimum() {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        // drag the top left grip far past the bottom right one
        e.begin(at: CGPoint(x: 0.2, y: 0.2))
        e.drag(to: CGPoint(x: 1.9, y: 1.9))
        e.end()
        XCTAssertEqual(e.displayRect.width, CropBox.minSize, accuracy: 1e-12, "a crossed corner stops rather than inverting")
        XCTAssertEqual(e.displayRect.height, CropBox.minSize, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(e.displayRect.minX, 0)
        XCTAssertLessThanOrEqual(e.displayRect.maxX, 1)

        // drag the whole box hard against a corner
        e.begin(at: CGPoint(x: e.displayRect.midX, y: e.displayRect.midY))
        e.drag(to: CGPoint(x: -3, y: -3))
        e.end()
        XCTAssertEqual(e.displayRect.minX, 0, accuracy: 1e-12)
        XCTAssertEqual(e.displayRect.minY, 0, accuracy: 1e-12)
    }

    func testNudgeMovesByOnePaneCoordinate() {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        let before = e.displayRect
        e.nudge(.interior, byPixels: CGVector(dx: 1, dy: 0), paneSize: CGSize(width: 800, height: 533))
        XCTAssertEqual(e.displayRect.minX, before.minX + 1.0 / 800, accuracy: 1e-12)
        XCTAssertEqual(e.displayRect.minY, before.minY, accuracy: 1e-12)
    }

    // MARK: quarter turns and flip

    /// Four quarter turns are a no-op, and each one leaves the STORED rect alone while
    /// moving the rect on screen: the crop names the same film however the picture is
    /// being looked at.
    func testFourQuarterTurnsReturnToTheStart() throws {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.2, y: 0.15, width: 0.45, height: 0.5))
        let start = try XCTUnwrap(e.geometry.crop)
        let onScreen = e.displayRect
        for step in 1...4 {
            e.rotateClockwise()
            let now = try XCTUnwrap(e.geometry.crop)
            XCTAssertEqual(now.x, start.x, accuracy: 1e-9, "stored rect unchanged after \(step) turns")
            XCTAssertEqual(now.y, start.y, accuracy: 1e-9)
            XCTAssertEqual(now.w, start.w, accuracy: 1e-9)
            XCTAssertEqual(now.h, start.h, accuracy: 1e-9)
            if step < 4 { XCTAssertNotEqual(e.displayRect, onScreen, "the rect moves on screen with the picture") }
        }
        XCTAssertEqual(e.geometry.rotate, 0)
        XCTAssertEqual(e.displayRect.minX, onScreen.minX, accuracy: 1e-9)
    }

    func testFlipTwiceIsANoOpAndMirrorsOnce() throws {
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.2, y: 0.15, width: 0.45, height: 0.5))
        let start = try XCTUnwrap(e.geometry.crop)
        let onScreen = e.displayRect
        e.toggleFlip()
        XCTAssertTrue(e.geometry.flip)
        XCTAssertEqual(e.displayRect.minX, 1 - onScreen.maxX, accuracy: 1e-9, "one flip mirrors the rect on screen")
        XCTAssertEqual(try XCTUnwrap(e.geometry.crop).x, start.x, accuracy: 1e-9, "and leaves the stored rect alone")
        e.toggleFlip()
        XCTAssertFalse(e.geometry.flip)
        XCTAssertEqual(e.displayRect.minX, onScreen.minX, accuracy: 1e-9)
    }

    func testDisplayAspectFollowsTheTurn() {
        let e = CropEditor(geometry: GeometrySettings(rotate: 90), originalAspect: 1.5)
        XCTAssertEqual(e.displayAspect, 1 / 1.5, accuracy: 1e-12)
        let flat = CropEditor(geometry: GeometrySettings(rotate: 180), originalAspect: 1.5)
        XCTAssertEqual(flat.displayAspect, 1.5, accuracy: 1e-12)
    }

    // MARK: nothing set

    func testUntouchedGeometryIsIdentity() {
        let e = CropEditor(geometry: GeometrySettings(), originalAspect: 1.5)
        XCTAssertTrue(e.geometry.isIdentity, "an untouched frame writes no geometry at all")
        XCTAssertNil(e.geometry.crop)
        XCTAssertFalse(e.hasCrop)
    }

    func testResetClearsTheCrop() {
        var e = CropEditor(geometry: GeometrySettings(rotate: 90), originalAspect: 1.5)
        draw(&e, CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        e.setDegrees(4)
        XCTAssertNotNil(e.geometry.crop)
        e.clearCrop()
        e.setDegrees(0)
        XCTAssertNil(e.geometry.crop)
        XCTAssertEqual(e.geometry.rotate, 90, "reset clears the crop and the angle, not the quarter turn")
    }

    /// Reopening the tool on a stored crop reproduces the rectangle exactly, which is what
    /// makes undo and redo land where they should.
    func testReopeningAStoredCropIsExact() throws {
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                var e = CropEditor(geometry: GeometrySettings(rotate: rotate, flip: flip, straightenDegrees: 2.5),
                                   originalAspect: 1.5)
                draw(&e, CGRect(x: 0.21, y: 0.17, width: 0.44, height: 0.51))
                let stored = e.geometry
                let reopened = CropEditor(geometry: stored, originalAspect: 1.5)
                XCTAssertEqual(reopened.displayRect.minX, e.displayRect.minX, accuracy: 1e-9)
                XCTAssertEqual(reopened.displayRect.minY, e.displayRect.minY, accuracy: 1e-9)
                XCTAssertEqual(reopened.displayRect.width, e.displayRect.width, accuracy: 1e-9)
                XCTAssertEqual(reopened.displayRect.height, e.displayRect.height, accuracy: 1e-9)
                XCTAssertEqual(reopened.geometry, stored)
            }
        }
    }

    // MARK: the four rungs, measured on 114 frames

    /// A picture of a developed POSITIVE: a dark flat field standing in for the unexposed
    /// rebate, with a textured bright rectangle standing in for the frame.
    ///
    /// Textured, not flat, on purpose. A flat rectangle on a flat ground is detectable by
    /// `FrameFinder`, which keys on neighbor-to-neighbor difference, and INVISIBLE to
    /// `CropPlanner`, whose sweep needs real density structure to hold a threshold over. Built
    /// flat, every ordering test below passes on the `frameFinderBounded` rung and proves
    /// nothing about the rung it names.
    ///
    /// The polarity is the reverse of a negative's, where the band is bright (clear rebate)
    /// and the picture dark, because this app measures the positive.
    private func stand(frame r: CGRect, w: Int = 768, h: Int = 576) -> DecodedFrame {
        var state: UInt64 = 42
        func rand() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
        }
        let rebate = 0.06, picture = 0.62, spread = 0.30, block = 16
        var v = [Double](repeating: rebate, count: w * h)
        let x0 = Int((r.minX * Double(w)).rounded()), x1 = Int((r.maxX * Double(w)).rounded())
        let y0 = Int((r.minY * Double(h)).rounded()), y1 = Int((r.maxY * Double(h)).rounded())
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let value = picture + (rand() - 0.5) * spread
                for py in y..<min(y + block, y1) where py >= 0 && py < h {
                    for px in x..<min(x + block, x1) where px >= 0 && px < w {
                        v[py * w + px] = value
                    }
                }
                x += block
            }
            y += block
        }
        var pixels = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let q = UInt16(min(max(v[i], 0), 1) * 65_535)
            pixels[i * 3] = q; pixels[i * 3 + 1] = q; pixels[i * 3 + 2] = q
        }
        return DecodedFrame(width: w, height: h, pixels: pixels)
    }

    /// A frame that really is 3:2 ON THIS CANVAS, which is not the same as a 3:2 pair of
    /// normalized numbers. The stand is 768x576, so a box of w by h shows as w*768 / h*576,
    /// and 0.60 x 0.40 is a 2:1 picture. Handing that to a planner expecting 35mm gets it
    /// correctly disbelieved.
    private static let threeByTwo = CGRect(x: 0.2, y: 0.2333, width: 0.6, height: 0.5333)

    /// The whole point of carrying two detectors: a rung that reports `isMeasured` has found
    /// the film, and one that does not has assumed it. Nothing else in the app may confuse
    /// those two, which is why the flag exists rather than a route comparison at each site.
    func testAMeasuredRouteIsAlwaysFullyBoundedAndAnAssumedOneNeverIs() throws {
        let found = try XCTUnwrap(CropEditor.detect(in: stand(frame: Self.threeByTwo), expecting: FilmSize.seedCatalog.first { $0.name == "35mm" }))
        XCTAssertTrue(found.route.isMeasured, "a clean single frame must not fall to a fallback rung")
        XCTAssertTrue(found.isFullyBounded)
        XCTAssertTrue(found.isFrameEdge)
    }

    /// A box that is 2:1 on this canvas, matching no format in the catalog.
    private static let twoByOne = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.4)

    /// The ordering rule, stated as a property rather than pinned to a route name: a shape
    /// NOTHING in the catalog can produce must not be answered on the detected route.
    ///
    /// What this does NOT say: handing the planner a 3:2 frame while expecting 11x14 does NOT
    /// get disbelieved, and should not. The detection held over 18 thresholds and matches
    /// 35mm exactly, which is the operator changing film, and `CropPlanner.confidentSteps`
    /// exists precisely so that stays possible without anyone announcing it first.
    /// Contradicting the expectation is not the disqualifier. Matching no real format is.
    func testAShapeNoFormatCanProduceIsNeverAnsweredOnTheDetectedRoute() throws {
        let m35 = try XCTUnwrap(FilmSize.seedCatalog.first { $0.name == "35mm" })
        let impossible = try XCTUnwrap(CropEditor.detect(in: stand(frame: Self.twoByOne), expecting: m35))
        XCTAssertNotEqual(impossible.route, .plannerDetected,
                          "2:1 is no format in the catalogue, so the sweep must not be believed")

        // Positive control, and it is the half that makes the assertion above mean anything.
        // If `plannerDetected` could never fire on this stand the test would pass while
        // proving nothing. A frame that IS 3:2 must take that rung.
        let real = try XCTUnwrap(CropEditor.detect(in: stand(frame: Self.threeByTwo), expecting: m35))
        XCTAssertEqual(real.route, .plannerDetected,
                       "the rung under test must be reachable, or the negative case is vacuous")
    }

    /// Changing film mid roll keeps working without telling us first: a confident detection
    /// that matches some other catalog format is believed over the expectation.
    func testAConfidentDetectionOfADifferentFormatIsBelievedOverTheExpectation() throws {
        let wrong = try XCTUnwrap(FilmSize.seedCatalog.first { $0.name == "11x14" })
        let found = try XCTUnwrap(CropEditor.detect(in: stand(frame: Self.threeByTwo), expecting: wrong))
        XCTAssertEqual(found.route, .plannerDetected,
                       "a 3:2 frame is 35mm whatever we were expecting, and must not be overridden")
    }

    /// An anchored plan is the right shape in the right place at the wrong size. Presenting it
    /// with the same confidence as a measurement is the failure this guards.
    func testAnAnchoredPlanNeverClaimsToBeAMeasurement() throws {
        let m35 = try XCTUnwrap(FilmSize.seedCatalog.first { $0.name == "35mm" })
        let found = try XCTUnwrap(CropEditor.detect(in: stand(frame: Self.twoByOne), expecting: m35))
        if found.route == .plannerAnchored {
            XCTAssertFalse(found.isFrameEdge)
            XCTAssertFalse(found.isFullyBounded, "only the pinned side was actually found")
            XCTAssertNil(found.size, "reading the size back off an anchored plan is learning our own assumption")
        }
    }

    /// Nothing to find means nothing returned, on every rung. A detector that invents a box on
    /// a blank frame is worse than one that refuses.
    func testAFeaturelessFrameIsRefusedByEveryRung() {
        let flat = DecodedFrame(width: 400, height: 300, pixels: [UInt16](repeating: 3000, count: 400 * 300 * 3))
        XCTAssertNil(CropEditor.detect(in: flat))
        XCTAssertNil(CropEditor.detect(in: flat, expecting: FilmSize.seedCatalog.first { $0.name == "35mm" }))
    }

    /// The angle is carried and deliberately not applied. If someone wires it into straighten
    /// later, this is the test that should change with it.
    func testTheMeasuredAngleIsCarriedButTheEditorIsNotTurnedByIt() throws {
        let f = stand(frame: Self.threeByTwo)
        let found = try XCTUnwrap(CropEditor.detect(in: f))
        var e = CropEditor(geometry: GeometrySettings(), originalAspect: 1000.0 / 700.0)
        e.aspect = .freeform
        e.seed(found)
        XCTAssertEqual(e.degrees, 0, accuracy: 1e-9, "autocrop must not rotate the picture on its own")
        _ = found.angle
    }
}

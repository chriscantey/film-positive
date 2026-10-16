import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Which way a straightened frame leans, when the frame is mirrored.
///
/// A scan from Film Tether carries `Flip="True"`. Get the handedness wrong and a scan
/// straightened in the editor leans one way in the preview and the OTHER way in the saved
/// render after Done. A test roll with `Flip` false never shows it.
///
/// The mechanism is one line of handedness. `straightenDegrees` lives in RAW space, before
/// the mirror, because the engine's chain is straighten, crop, rotate, flip. The preview
/// turns the DISPLAY image, which already has the mirror in it. A mirror reverses
/// handedness, so the same number means opposite directions in the two places. A quarter
/// turn does not reverse handedness, which is why only `flip` matters.
///
/// These run in the FAST test filter on purpose. They are pure arithmetic over a 240x160 synthetic
/// frame, and the suite that holds the rest of the crop arithmetic is skipped by default.
final class CropStraightenSignTests: XCTestCase {

    private let w = 240
    private let h = 160
    private var aspect: CGFloat { CGFloat(w) / CGFloat(h) }

    // MARK: the conversion itself

    /// With no mirror the two readings are the same number, which is the case that has
    /// always worked and must keep working.
    func testAnUnflippedFrameStoresTheAngleTheUserSees() {
        var e = CropEditor(geometry: GeometrySettings(rotate: 0, flip: false), originalAspect: aspect)
        e.setDisplayDegrees(5)
        XCTAssertEqual(e.degrees, 5, accuracy: 1e-12, "stored angle")
        XCTAssertEqual(e.displayDegrees, 5, accuracy: 1e-12, "and it reads back the same on screen")
    }

    /// With the mirror on, the same lean on screen is the opposite angle in the sidecar.
    func testAFlippedFrameStoresTheOppositeOfWhatTheUserSees() {
        var e = CropEditor(geometry: GeometrySettings(rotate: 0, flip: true), originalAspect: aspect)
        e.setDisplayDegrees(5)
        XCTAssertEqual(e.degrees, -5, accuracy: 1e-12, "the sidecar angle is raw space, before the mirror")
        XCTAssertEqual(e.displayDegrees, 5, accuracy: 1e-12, "and it still reads as the user left it")
        XCTAssertEqual(e.geometry.straightenDegrees, -5, accuracy: 1e-12, "which is what gets written")
    }

    /// A quarter turn keeps handedness, so it must not touch either reading.
    func testAQuarterTurnDoesNotChangeTheReading() {
        for rotate in [0, 90, 180, 270] {
            var e = CropEditor(geometry: GeometrySettings(rotate: rotate, flip: false), originalAspect: aspect)
            e.setDisplayDegrees(7.5)
            XCTAssertEqual(e.degrees, 7.5, accuracy: 1e-12, "stored at rotate \(rotate)")
            XCTAssertEqual(e.displayDegrees, 7.5, accuracy: 1e-12, "on screen at rotate \(rotate)")
        }
    }

    /// Pressing Flip must not move the picture the user has already levelled. Leaving the
    /// stored angle alone would tilt a levelled horizon by twice the angle the instant the
    /// button is pressed.
    func testPressingFlipKeepsThePictureLeaningTheWayItLeans() {
        var e = CropEditor(geometry: GeometrySettings(rotate: 0, flip: false), originalAspect: aspect)
        e.setDisplayDegrees(4)
        XCTAssertEqual(e.degrees, 4, accuracy: 1e-12)

        e.toggleFlip()
        XCTAssertEqual(e.displayDegrees, 4, accuracy: 1e-12, "the lean on screen did not move")
        XCTAssertEqual(e.degrees, -4, accuracy: 1e-12, "so the stored angle had to")

        e.toggleFlip()
        XCTAssertEqual(e.displayDegrees, 4, accuracy: 1e-12, "and back again")
        XCTAssertEqual(e.degrees, 4, accuracy: 1e-12)
    }

    // MARK: the preview and the engine agree

    /// The preview draws the base image, which is the frame with the mirror and the quarter
    /// turn applied and NO straighten, and turns it by `displayDegrees`. So the film the user
    /// sees under a point of the preview is that point un-turned by `displayDegrees` in
    /// display space, then mapped down through the mirror and the turn.
    ///
    /// The engine says the film under that same point is `rawOriginalPoint(fromDisplay:)`,
    /// which goes the other way round: down through the mirror and the turn first, then
    /// un-straighten by the STORED angle.
    ///
    /// Those two have to name the same film, for all eight orientations, or the picture
    /// moves between the preview and Done. A conversion that ignores the mirror puts every
    /// `flip == true` case out by twice the angle.
    func testThePreviewAndTheEngineNameTheSameFilm() {
        let probes = [CGPoint(x: 0.30, y: 0.25), CGPoint(x: 0.72, y: 0.61), CGPoint(x: 0.5, y: 0.5)]
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                for display in [6.0, -9.25] {
                    var e = CropEditor(geometry: GeometrySettings(rotate: rotate, flip: flip), originalAspect: aspect)
                    e.setDisplayDegrees(display)
                    for p in probes {
                        // What the preview shows under p.
                        let unturned = FineRotation.unstraightened(p, byDegrees: e.displayDegrees,
                                                                   aspect: e.displayAspect)
                        let previewSays = CropEditor.originalPoint(fromDisplay: unturned, turn: QuarterTurn(degrees: rotate)!, flip: flip)
                        // What the engine puts there.
                        let engineSays = e.rawOriginalPoint(fromDisplay: p)
                        let label = "rotate \(rotate) flip \(flip) display \(display) at \(p)"
                        XCTAssertEqual(Double(previewSays.x), Double(engineSays.x), accuracy: 1e-9, "x, \(label)")
                        XCTAssertEqual(Double(previewSays.y), Double(engineSays.y), accuracy: 1e-9, "y, \(label)")
                    }
                }
            }
        }
    }

    /// The same claim with real pixels through the engine, on the hard case: mirrored,
    /// straightened, cropped.
    ///
    /// A ramp frame encodes its own coordinates, so every pixel that comes out of
    /// `Straighten.apply` reports which film it came from. The work is all done in
    /// straightened-original space, which is the space the stored crop lives in and the
    /// space `Straighten.apply` outputs, so there is no mirror bookkeeping on the test's
    /// side to get wrong.
    ///
    /// Two assertions per point. The first is a canary: the pixel the engine produced came
    /// from where the engine's own point mapping says, which fails loudly if the ramp or
    /// the decode is broken and would otherwise make the second assertion vacuous. The
    /// second is the claim: the preview, turning the display image by `displayDegrees`,
    /// was showing that same film. A conversion that ignores the mirror puts the second one
    /// out by twice the angle for every mirrored frame.
    func testTheCroppedPixelsAreTheFilmThePreviewShowed() throws {
        let f0 = ramp(w, h)
        let drawn = CGRect(x: 0.28, y: 0.22, width: 0.34, height: 0.36)
        for flip in [false, true] {
            var e = CropEditor(geometry: GeometrySettings(rotate: 0, flip: flip), originalAspect: aspect)
            e.setDisplayDegrees(8)
            draw(&e, drawn)
            let g = e.geometry
            let crop = try XCTUnwrap(g.crop)
            let cropped = Straighten.apply(f0, degrees: g.straightenDegrees, crop: crop)
            XCTAssertGreaterThan(cropped.width, 8, "the crop produced pixels to read")

            for (fx, fy) in [(0.5, 0.5), (0.2, 0.3), (0.75, 0.7)] {
                let cx = Int(Double(cropped.width) * fx), cy = Int(Double(cropped.height) * fy)
                let decoded = position(of: cropped.pixels, at: (cy * cropped.width + cx) * 3, w: w, h: h)
                let label = "flip \(flip) at \(fx), \(fy)"

                // The same output pixel as a point of straightened-original space.
                let straightened = CGPoint(
                    x: crop.x + (Double(cx) + 0.5) / Double(cropped.width) * crop.w,
                    y: crop.y + (Double(cy) + 0.5) / Double(cropped.height) * crop.h)

                // Canary: the engine's own mapping predicts the pixel it produced.
                let engineSays = FineRotation.unstraightened(straightened, byDegrees: g.straightenDegrees, aspect: aspect)
                XCTAssertEqual(Double(decoded.x), Double(engineSays.x), accuracy: 2.5 / Double(w), "canary x, \(label)")
                XCTAssertEqual(Double(decoded.y), Double(engineSays.y), accuracy: 2.5 / Double(h), "canary y, \(label)")

                // The claim: the preview was showing that film at that place on screen.
                // Where the point sits on screen, then back down the preview's own route:
                // un-turn by the DISPLAY angle in display space, then through the mirror.
                let onScreen = CropEditor.displayPoint(fromOriginal: straightened, turn: QuarterTurn.none, flip: flip)
                let unturned = FineRotation.unstraightened(onScreen, byDegrees: e.displayDegrees, aspect: e.displayAspect)
                let previewSays = CropEditor.originalPoint(fromDisplay: unturned, turn: QuarterTurn.none, flip: flip)
                XCTAssertEqual(Double(previewSays.x), Double(decoded.x), accuracy: 2.5 / Double(w), "preview x, \(label)")
                XCTAssertEqual(Double(previewSays.y), Double(decoded.y), accuracy: 2.5 / Double(h), "preview y, \(label)")
            }
        }
    }

    // MARK: synthetic frames, the same helpers CropEditorTests uses

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

    /// Drive the editor the way a user does, through the gesture API, with the ratio lock
    /// off so the drawn rectangle is the one that gets stored.
    private func draw(_ e: inout CropEditor, _ r: CGRect) {
        e.aspect = .freeform
        e.begin(at: CGPoint(x: 0, y: 0))
        e.drag(to: CGPoint(x: r.minX, y: r.minY))
        e.end()
        e.begin(at: CGPoint(x: 1, y: 1))
        e.drag(to: CGPoint(x: r.maxX, y: r.maxY))
        e.end()
    }
}

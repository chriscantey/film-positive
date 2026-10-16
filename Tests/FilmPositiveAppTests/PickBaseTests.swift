import XCTest
import CoreGraphics
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Pick Base, the eyedropper, and two of its rules.
///
/// The first is the mapping: a click arrives in view space after the quarter turn, the
/// mirror and the aspect-fit letterbox, and it has to come back as a point in the decode's
/// own space. That half is tested against `Geometry.orient` as ground truth, with no SwiftUI
/// anywhere near it, at four ASYMMETRIC corners so a transposed axis or a missing
/// reflection fails rather than passing by symmetry.
///
/// The second is the write shape: all N frames in ONE undo group, Clear Base over the same
/// set, and a band refusal that writes nothing at all.
final class PickBaseTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-pick-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: RIDER 2, the mapping

    /// A frame painted so every corner is a different, known color, with the quadrant
    /// values chosen to be far apart: a patch that lands in the wrong one is off by tens of
    /// thousands of code values, not by a rounding error.
    private func cornerFrame(width: Int, height: Int) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let left = x < width / 2, top = y < height / 2
                let v: (UInt16, UInt16, UInt16)
                switch (left, top) {
                case (true, true):   v = (10000, 20000, 30000)   // top left
                case (false, true):  v = (11000, 22000, 33000)   // top right
                case (true, false):  v = (12000, 24000, 36000)   // bottom left
                case (false, false): v = (13000, 26000, 39000)   // bottom right
                }
                let i = (y * width + x) * 3
                px[i] = v.0; px[i + 1] = v.1; px[i + 2] = v.2
            }
        }
        return DecodedFrame(width: width, height: height, pixels: px)
    }

    /// The corner test. For every combination of quarter turn and mirror, a click near each
    /// of the four DISPLAY corners maps back to a decode point whose patch mean equals the
    /// value that `Geometry.orient` actually put in that display corner.
    ///
    /// `Geometry.orient` is the ground truth rather than a second copy of the arithmetic:
    /// it is the function the engine uses to build the picture the user is clicking on, so
    /// sampling the ORIENTED frame at the display point and the RAW frame at the mapped
    /// point must agree. A sign error in `PickBaseMapping` breaks that agreement in exactly
    /// one of the eight cases, which is why all eight run.
    func testPicksAtFourAsymmetricCornersOfARotatedAndFlippedFrame() throws {
        let raw = cornerFrame(width: 800, height: 600)
        // Well inside each corner: far enough in that the whole patch is within one
        // quadrant, so the expected mean is exact.
        let corners: [(name: String, point: CGPoint)] = [
            ("top left", CGPoint(x: 0.12, y: 0.15)),
            ("top right", CGPoint(x: 0.88, y: 0.15)),
            ("bottom left", CGPoint(x: 0.12, y: 0.85)),
            ("bottom right", CGPoint(x: 0.88, y: 0.85)),
        ]

        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                let oriented = Geometry.orient(raw, flip: flip, rotate: rotate)
                let mapping = PickBaseMapping(rotate: rotate, flip: flip)
                for corner in corners {
                    let label = "rotate \(rotate) flip \(flip) at \(corner.name)"
                    // What is really on screen at that display point, measured on the
                    // oriented frame the pane is showing.
                    let expected = try XCTUnwrap(
                        Calibrator.patchEstimate(oriented, at: corner.point, radius: 0.02),
                        "the oriented frame has no reading at \(label)")
                    // What the pick samples: the mapped point on the RAW decode.
                    let decodePoint = mapping.decodePoint(fromDisplay: corner.point)
                    let got = try XCTUnwrap(
                        Calibrator.patchEstimate(raw, at: decodePoint, radius: 0.02),
                        "the mapped point has no reading at \(label)")
                    for c in 0..<3 {
                        XCTAssertEqual(got[c], expected[c], accuracy: 1,
                                       "channel \(c) at \(label): the mapping put the patch "
                                       + "in the wrong part of the decode")
                    }
                }
            }
        }
    }

    /// The mapping is a bijection: forward then back is the identity, for every case. Cheap,
    /// and it catches an inverse that is right in three cases and wrong in the fourth.
    func testTheMappingRoundTripsBothWays() {
        let probes = [CGPoint(x: 0.03, y: 0.97), CGPoint(x: 0.41, y: 0.18),
                      CGPoint(x: 0.66, y: 0.52), CGPoint(x: 0.99, y: 0.01)]
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                let m = PickBaseMapping(rotate: rotate, flip: flip)
                for p in probes {
                    let there = m.displayPoint(fromDecode: p)
                    let back = m.decodePoint(fromDisplay: there)
                    XCTAssertEqual(back.x, p.x, accuracy: 1e-12, "rotate \(rotate) flip \(flip)")
                    XCTAssertEqual(back.y, p.y, accuracy: 1e-12, "rotate \(rotate) flip \(flip)")
                }
            }
        }
    }

    /// The moving square is drawn by projecting the SAMPLED rect back through the mapping,
    /// so the rect has to come back containing the display point it was built from. Under a
    /// quarter turn the patch's normalized shape transposes, which is the case a naive
    /// square-in-normalized-coordinates overlay gets wrong.
    func testTheDrawnPatchRectContainsTheClickAndTransposesUnderAQuarterTurn() {
        let decodeW = 800, decodeH = 600
        let click = CGPoint(x: 0.3, y: 0.7)
        for rotate in [0, 90, 180, 270] {
            for flip in [false, true] {
                let m = PickBaseMapping(rotate: rotate, flip: flip)
                let point = m.decodePoint(fromDisplay: click)
                let patch = PickBaseMapping.patchRect(around: point, radius: 0.02,
                                                      width: decodeW, height: decodeH)
                let shown = m.displayRect(fromDecode: patch)
                XCTAssertTrue(shown.insetBy(dx: -1e-9, dy: -1e-9).contains(click),
                              "rotate \(rotate) flip \(flip): the square must sit under the cursor")
                // 16 px each way on an 800x600 decode: 0.02 of the width, 0.02667 of the
                // height. A quarter turn swaps which of those is the screen's x.
                let wide = rotate == 90 || rotate == 270
                XCTAssertEqual(shown.width, wide ? 2 * 16.0 / 600 : 2 * 16.0 / 800, accuracy: 1e-9,
                               "rotate \(rotate) flip \(flip)")
            }
        }
    }

    // MARK: (b) the loupe's placement

    /// The one radius. The drawing, the readout, the click and the gallery mode all read
    /// it, so a test that pins the value is what keeps a future edit from moving the
    /// picture without moving the number.
    func testThePatchRadiusIsStatedOnce() {
        XCTAssertEqual(PickBasePatch.radius, 0.01, accuracy: 1e-12)
        let r = PickBaseMapping.patchRect(around: CGPoint(x: 0.5, y: 0.5),
                                          radius: PickBasePatch.radius, width: 2000, height: 1500)
        XCTAssertEqual(r.width * 2000, 40, accuracy: 1e-9, "41 pixels across on a 2000 wide proxy")
    }

    // MARK: the gallery loupe

    /// The gallery loupe sits ON the pointer, not beside it. Offset up and left, the circle
    /// lands on a neighboring cell while magnifying the frame under the pointer.
    func testTheGalleryLoupeIsCentredOnThePointerAndOnlyMovesAtAnEdge() {
        let content = CGSize(width: 900, height: 700)
        let d = PickBasePatch.loupeDiameter

        // Interior: the circle's center IS the pointer, both axes, and the label is
        // centered under it.
        let cursor = CGPoint(x: 400, y: 300)
        let p = PickBaseLoupe.place(cursor: cursor, in: content)
        XCTAssertEqual(p.loupeCenter.x, cursor.x, accuracy: 1e-9)
        XCTAssertEqual(p.loupeCenter.y, cursor.y, accuracy: 1e-9)
        XCTAssertEqual(p.label.x + PickBasePanel.width / 2, cursor.x, accuracy: 1e-9,
                       "the label is centred under the circle away from the edges")
        XCTAssertEqual(p.label.y, p.loupe.y + d + PickBasePanel.gap, accuracy: 1e-9,
                       "and sits directly below it")

        // At every corner the LABEL stays inside the content and the circle does not move.
        for c in [CGPoint(x: 2, y: 2), CGPoint(x: 898, y: 2),
                  CGPoint(x: 2, y: 698), CGPoint(x: 898, y: 698)] {
            let q = PickBaseLoupe.place(cursor: c, in: content)
            XCTAssertEqual(q.loupeCenter.x, c.x, accuracy: 1e-9, "at \(c)")
            XCTAssertEqual(q.loupeCenter.y, c.y, accuracy: 1e-9, "at \(c)")
            XCTAssertGreaterThanOrEqual(q.label.x, 0, "at \(c)")
            XCTAssertGreaterThanOrEqual(q.label.y, 0, "at \(c)")
            XCTAssertLessThanOrEqual(q.label.x + PickBasePanel.width, content.width + 1e-9, "at \(c)")
            XCTAssertLessThanOrEqual(q.label.y + PickBasePanel.labelHeight,
                                     content.height + 1e-9, "at \(c)")
        }

        // Near the bottom the label flips ABOVE the circle rather than riding over it.
        let low = PickBaseLoupe.place(cursor: CGPoint(x: 400, y: 690), in: content)
        XCTAssertLessThan(low.label.y + PickBasePanel.labelHeight, low.loupe.y + 1e-9,
                          "flipped above the circle")
    }

    /// The eyedropper is off on a selection that agrees on black and white, everywhere.
    /// The Positive menu offering it while the inspector's own dropper beside it is greyed
    /// out would be the interface contradicting itself.
    @MainActor
    func testTheEyedropperIsOffOnAMonoSelectionAndOnAgreementOnly() throws {
        let (m, ids, _) = try model(count: 3)

        m.selection = [ids[0]]
        XCTAssertTrue(m.canPickBase, "a colour frame picks")

        seedStock(m, ids[0], "bw-generic")
        XCTAssertTrue(try XCTUnwrap(m.frame(ids[0]).map(m.isMonoStock)), "the stock resolves mono")
        XCTAssertFalse(m.canPickBase, "a B&W selection has no colour base to measure")

        // Agreement is the condition, the same rule the Base control follows: one
        // color frame in the set keeps the tool live, because the pick is a real edit
        // to that frame.
        m.selection = [ids[0], ids[1]]
        XCTAssertTrue(m.canPickBase, "a mixed selection stays live")

        // And the gallery item, whose targets fall back to the clicked frame.
        let mono = try XCTUnwrap(m.frame(ids[0]))
        let colour = try XCTUnwrap(m.frame(ids[1]))
        m.selection = []
        XCTAssertFalse(m.canPickBase(from: mono), "right clicking a B&W frame with nothing selected")
        XCTAssertTrue(m.canPickBase(from: colour))

        // Leaving the mode is always allowed, whatever the selection resolves to.
        m.selection = [ids[0]]
        m.isPickingBase = true
        XCTAssertTrue(m.canPickBase)
    }

    /// Writes a stock onto one frame through the ordinary edit path, so the defaults commit
    /// the way they do in the app.
    @MainActor
    private func seedStock(_ m: AppModel, _ id: Frame.ID, _ stock: String) {
        guard let frame = m.frame(id), var develop = m.renders.defaults.initial(for: frame.sidecar) else {
            return XCTFail("no defaults for the frame")
        }
        develop.stock = stock
        // The harness turns automatic grouping off, so the group has to be explicit or the
        // undo manager refuses the registration.
        m.undoManager.beginUndoGrouping()
        m.apply({ SidecarEdits.setDevelop($0, develop) }, to: id, actionName: "seed")
        m.undoManager.endUndoGrouping()
    }

    // MARK: the closeup aims at the raw negative

    /// The closeup and the gallery orient the picture with ONE function, so the pane's
    /// pixels and `PickBaseMapping` cannot describe different rectangles of film. This
    /// asserts they are the same function rather than two that happen to agree today.
    func testTheCloseupAndTheGalleryOrientTheNegativeIdentically() {
        let cases = [
            GeometrySettings(rotate: 0, flip: false),
            GeometrySettings(rotate: 90, flip: true, straightenDegrees: 1.5,
                             crop: CropRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4)),
            GeometrySettings(rotate: 180, flip: false, straightenDegrees: -3,
                             crop: CropRect(x: 0, y: 0, w: 1, h: 1)),
            GeometrySettings(rotate: 270, flip: true),
        ]
        for g in cases {
            let closeup = PickBaseNegative.geometry(g)
            XCTAssertEqual(closeup, GalleryPick.pickGeometry(g),
                           "the two sites must share one orientation, not two copies of it")
            XCTAssertEqual(closeup.rotate, ((g.rotate % 360) + 360) % 360, "the turn survives")
            XCTAssertEqual(closeup.flip, g.flip, "and the mirror")
            XCTAssertEqual(closeup.straightenDegrees, 0, accuracy: 1e-12, "the straighten is stripped")
            XCTAssertNil(closeup.crop, "and the crop, which the film base sits outside of")
            // And the mapping the click goes through is built on exactly that.
            let m = PickBaseMapping(geometry: closeup)
            XCTAssertEqual(m.rotate, closeup.rotate)
            XCTAssertEqual(m.flip, closeup.flip)
        }
        // Nil geometry is the undeveloped frame, which must still be pickable.
        XCTAssertEqual(PickBaseNegative.geometry(nil), GeometrySettings())
    }

    /// The closeup reads the negative at a long edge that suits a full window. The gallery's
    /// 512 is the thumbnail's, and blowing it up across a closeup is the soft picture the
    /// eyedropper was meant to stop being.
    func testTheCloseupNegativeIsDecodedLargerThanAThumbnail() {
        XCTAssertEqual(PickBaseNegative.maxEdge, 2400)
        XCTAssertGreaterThan(PickBaseNegative.maxEdge, NegativeThumbnail.defaultMaxEdge)
        XCTAssertGreaterThan(PickBaseNegative.maxEdge, GalleryPickHover.sharpMaxEdge,
                             "a full window needs more than the gallery loupe does")
    }

    /// The picture's identity is the file AND its orientation, so turning a frame while the
    /// mode is on re-decodes rather than leaving the old turn on screen under a mapping that
    /// has already moved.
    func testTheCloseupNegativeIsKeyedOnTheFileAndItsOrientation() {
        let url = URL(fileURLWithPath: "/tmp/IMG_0001.CR2")
        let other = URL(fileURLWithPath: "/tmp/IMG_0002.CR2")
        let a = PickBaseNegative.Key(url: url, geometry: PickBaseNegative.geometry(GeometrySettings()))
        let b = PickBaseNegative.Key(url: url, geometry: PickBaseNegative.geometry(GeometrySettings()))
        let turned = PickBaseNegative.Key(url: url,
                                          geometry: PickBaseNegative.geometry(GeometrySettings(rotate: 90)))
        let elsewhere = PickBaseNegative.Key(url: other,
                                             geometry: PickBaseNegative.geometry(GeometrySettings()))
        XCTAssertEqual(a, b, "the same frame at the same turn is one decode")
        XCTAssertNotEqual(a, turned, "a quarter turn is a different picture")
        XCTAssertNotEqual(a, elsewhere, "and so is another frame")
        // A crop or a straighten is NOT part of it: neither one reaches the picture.
        let cropped = PickBaseNegative.Key(
            url: url,
            geometry: PickBaseNegative.geometry(GeometrySettings(rotate: 0, flip: false,
                                                                 straightenDegrees: 4,
                                                                 crop: CropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5))))
        XCTAssertEqual(a, cropped, "a crop does not change the picture the eyedropper aims at")
    }

    /// The closeup places the circle by the SAME rule as the gallery, in the same
    /// coordinate space as the sample it is showing.
    func testTheCloseupCircleIsCentredOnTheCursorLikeTheGalleryIs() {
        let pane = CGSize(width: 1200, height: 800)
        for cursor in [CGPoint(x: 600, y: 400), CGPoint(x: 200, y: 700), CGPoint(x: 950, y: 120)] {
            let p = PickBaseLoupe.place(cursor: cursor, in: pane)
            XCTAssertEqual(p.loupeCenter.x, cursor.x, accuracy: 1e-9, "at \(cursor)")
            XCTAssertEqual(p.loupeCenter.y, cursor.y, accuracy: 1e-9, "at \(cursor)")
        }
        // One set of sizes for both surfaces, so neither can place a different thing.
        XCTAssertEqual(PickBasePanel.size.width, PickBasePanel.width)
        XCTAssertEqual(PickBasePanel.size.height,
                       PickBasePatch.loupeDiameter + PickBasePanel.readoutHeight)
        XCTAssertEqual(PickBaseLoupe.readoutWidth, PickBasePanel.width)
    }

    /// The circle is NEVER clamped horizontally, so it stays on the pointer at the pane's
    /// own left edge. Clamped as one rectangle with the 124 wide LABEL, which hits the pane
    /// before the 96 wide circle does, it measured 24.5 points right of the pointer at the
    /// film's bottom left and 53 points right at the left edge, both pinned near x 725.
    func testTheCircleTracksThePointerAtThePanesLeftEdgeWhileTheLabelStaysReadable() {
        let pane = CGSize(width: 1400, height: 1000)
        let d = PickBasePatch.loupeDiameter

        // The measured case: ten points in from the pane's left edge.
        let cursor = CGPoint(x: 10, y: 571)
        let p = PickBaseLoupe.place(cursor: cursor, in: pane)
        XCTAssertEqual(p.loupeCenter.x, 10, accuracy: 1e-9,
                       "the circle centre is exactly the pointer, overhanging the edge")
        XCTAssertEqual(p.loupeCenter.y, 571, accuracy: 1e-9)
        XCTAssertEqual(p.loupe.x, 10 - d / 2, accuracy: 1e-9, "so its left edge is off the pane")
        // The label does not follow it off the pane.
        XCTAssertEqual(p.label.x, 0, accuracy: 1e-9, "the label clamps on its own")
        XCTAssertLessThanOrEqual(p.label.x + PickBasePanel.width, pane.width + 1e-9)

        // The measured pointers, in pane space, track exactly.
        for c in [CGPoint(x: 700, y: 832), CGPoint(x: 672, y: 571), CGPoint(x: 1069, y: 571)] {
            let q = PickBaseLoupe.place(cursor: c, in: pane)
            XCTAssertEqual(q.loupeCenter.x, c.x, accuracy: 1e-9, "at \(c)")
            XCTAssertEqual(q.loupeCenter.y, c.y, accuracy: 1e-9, "at \(c)")
        }

        // And the right edge, the top and the bottom: the circle never moves anywhere.
        for c in [CGPoint(x: 1395, y: 500), CGPoint(x: 700, y: 4), CGPoint(x: 700, y: 996)] {
            let q = PickBaseLoupe.place(cursor: c, in: pane)
            XCTAssertEqual(q.loupeCenter, c, "at \(c)")
            XCTAssertGreaterThanOrEqual(q.label.x, 0)
            XCTAssertGreaterThanOrEqual(q.label.y, 0)
            XCTAssertLessThanOrEqual(q.label.x + PickBasePanel.width, pane.width + 1e-9)
            XCTAssertLessThanOrEqual(q.label.y + PickBasePanel.labelHeight, pane.height + 1e-9)
        }
    }

    // MARK: the model harness

    /// A model over frames with no sidecars, the state a freshly copied roll is in. The
    /// real profile library, because the defaults resolve a capture film name through it.
    @MainActor
    private func model(count: Int = 4) throws -> (AppModel, [Frame.ID], URL) {
        let roll = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let profiles = try ProfileLibrary.bundled()
        let m = AppModel(service: CPURenderService(profiles: profiles))
        // A test has no run loop event, so automatic grouping would swallow every explicit
        // group and one undo would unwind the whole test.
        m.undoManager.groupsByEvent = false
        XCTAssertNotNil(m.addFolder(roll))
        let ids = (m.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (m, ids, roll)
    }

    /// A base that lands inside the band: raw R/G 0.47, which is what the edge reader
    /// measures off a real frame.
    private let goodMeans: [Double] = [14100, 30000, 21000]

    // MARK: (a) N writes, one undo group

    @MainActor
    func testAPickWritesEveryTargetInOneUndoGroup() throws {
        let (m, ids, _) = try model(count: 4)
        let targets = [ids[0], ids[1], ids[2]]
        m.selection = Set(targets)

        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)

        let expected = try XCTUnwrap(BaseResolver.ratios(fromRebate: goodMeans))
        for id in targets {
            let base = try XCTUnwrap(m.frame(id)?.sidecar.develop?.base)
            XCTAssertEqual(base.mode, .measured, "the mode says measured")
            XCTAssertEqual(try XCTUnwrap(base.ratios).rg, expected.rg, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(base.ratios).bg, expected.bg, accuracy: 1e-9)
            XCTAssertEqual(base.measured, [14100, 30000, 21000], "the triple that was measured")
        }
        XCTAssertNil(m.frame(ids[3])?.sidecar.develop, "the unselected frame is untouched")

        // ONE undo restores all three. This is the property a per-frame loop without the
        // explicit group would fail.
        XCTAssertTrue(m.undoManager.canUndo)
        m.undoManager.undo()
        for id in targets {
            XCTAssertNil(m.frame(id)?.sidecar.develop?.base.ratios,
                         "one undo takes the measured base off every frame it was written to")
        }
    }

    @MainActor
    func testTheModeEndsAfterAPickAndTheNoteNamesTheRatios() throws {
        let (m, ids, _) = try model(count: 2)
        m.selection = [ids[0]]
        m.beginPickingBase()
        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)
        XCTAssertFalse(m.isPickingBase, "a pick ends the mode")
        let note = try XCTUnwrap(m.pickBaseNote)
        XCTAssertTrue(note.contains("0.470"), "the note names the R/G that was written: \(note)")
        XCTAssertTrue(note.contains("1 frame"), "and how many frames: \(note)")
    }

    // MARK: (b) Clear Base, same set

    @MainActor
    func testClearBaseActsOnTheSameSetAndInOneGroup() throws {
        let (m, ids, _) = try model(count: 4)
        let targets = [ids[0], ids[1], ids[2]]
        m.selection = Set(targets)
        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)

        XCTAssertTrue(m.canClearBase)
        m.clearBase()

        for id in targets {
            let base = try XCTUnwrap(m.frame(id)?.sidecar.develop?.base)
            XCTAssertEqual(base.mode, .anchor, "back to auto")
            XCTAssertNil(base.ratios, "and no ratios left to win step 2 of the resolver")
        }
        XCTAssertFalse(m.canClearBase, "nothing measured is left to clear")

        m.undoManager.undo()
        for id in targets {
            XCTAssertEqual(m.frame(id)?.sidecar.develop?.base.mode, .measured,
                           "one undo puts the measured base back on every frame")
        }
    }

    // MARK: (c) Reuse Last Base, read back off the xmp

    @MainActor
    func testReuseLastBaseWritesTheSameRatiosAndTheyLandInTheFile() throws {
        let (m, ids, roll) = try model(count: 4)
        m.selection = [ids[0]]
        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)
        let picked = try XCTUnwrap(m.lastPickedBase)

        // A second, disjoint selection, the way a user would: pick on one frame, then put
        // that base on the rest of the roll.
        XCTAssertNil(m.frame(ids[2])?.sidecar.develop)
        m.selection = [ids[1], ids[2]]
        XCTAssertTrue(m.canReusePickedBase)
        m.reusePickedBase()

        for id in [ids[1], ids[2]] { m.flushPendingSave(id) }

        // Read the BYTES, not the model's memory: the point is what the file says.
        for name in ["IMG_0002", "IMG_0003"] {
            let loaded = try XCTUnwrap(SidecarStore().load(for: roll.appendingPathComponent(name + ".CR2")))
            let base = try XCTUnwrap(loaded.sidecar.develop?.base)
            XCTAssertEqual(base.mode, .measured, "\(name) carries a measured base")
            let ratios = try XCTUnwrap(base.ratios)
            // The sidecar quantizes ratios to four places on the way out, so the comparison
            // is against that rounding rather than against the full double.
            XCTAssertEqual(ratios.rg, (picked.rg * 10000).rounded() / 10000, accuracy: 1e-9)
            XCTAssertEqual(ratios.bg, (picked.bg * 10000).rounded() / 10000, accuracy: 1e-9)
            XCTAssertEqual(base.measured, m.lastPickedMeasured, "and the same measured triple")
        }

        XCTAssertEqual(m.frame(ids[3])?.sidecar.develop?.base.ratios, nil,
                       "the frame outside the second selection is untouched")
    }

    @MainActor
    func testReuseIsUnavailableUntilAPickExists() throws {
        let (m, ids, _) = try model(count: 2)
        m.selection = [ids[0]]
        XCTAssertNil(m.lastPickedBase)
        XCTAssertFalse(m.canReusePickedBase)
        m.reusePickedBase()
        XCTAssertNil(m.frame(ids[0])?.sidecar.develop, "reuse with nothing picked writes nothing")
    }

    // MARK: (d) the band refuses and writes nothing

    @MainActor
    func testABandRefusalWritesNothingAndSetsTheNote() throws {
        let (m, ids, roll) = try model(count: 2)
        m.selection = [ids[0], ids[1]]
        m.beginPickingBase()

        // R/G 5.0, well above the high bound: not film base under any scanner.
        m.applyPickedBase([50000, 10000, 12000], to: m.pickBaseTargets)

        XCTAssertNil(m.frame(ids[0])?.sidecar.develop, "a refused pick writes NOTHING")
        XCTAssertNil(m.frame(ids[1])?.sidecar.develop)
        XCTAssertFalse(m.undoManager.canUndo, "and takes no undo entry")
        XCTAssertNil(m.lastPickedBase, "and does not become the base to reuse")
        let note = try XCTUnwrap(m.pickBaseNote)
        XCTAssertTrue(note.contains("film base"), "the note says why: \(note)")
        XCTAssertTrue(m.isPickingBase, "the mode stays on so the user gets another click")

        for id in ids { m.flushPendingSave(id) }
        let files = try FileManager.default.contentsOfDirectory(atPath: roll.path)
            .filter { $0.hasSuffix("." + SidecarStore.ext) }
        XCTAssertEqual(files, [], "and nothing reached disk")
    }

    /// The band is stated on the RAW r/g the resolver compares, so the real values off a
    /// set of rolls must pass. The crop battery spans about 0.23 to 0.62, and a 0.8 floor
    /// would refuse every one of them.
    @MainActor
    func testTheBandAcceptsEveryRawRatioTheCropBatteryProduces() throws {
        for rg in [0.23, 0.30, 0.4671, 0.4743, 0.55, 0.62] {
            XCTAssertNil(PickBaseBand.refusal(for: BaseRatios(rg: rg, bg: 0.6)),
                         "a real measured base at R/G \(rg) must not be refused")
        }
        XCTAssertNotNil(PickBaseBand.refusal(for: BaseRatios(rg: 0.05, bg: 0.6)))
        XCTAssertNotNil(PickBaseBand.refusal(for: BaseRatios(rg: 4.0, bg: 0.6)))
        XCTAssertNotNil(PickBaseBand.refusal(for: BaseRatios(rg: .nan, bg: 0.6)))
        XCTAssertNotNil(PickBaseBand.refusal(for: BaseRatios(rg: 0.5, bg: 0)))
    }

    @MainActor
    func testAnUnmeasurablePickWritesNothing() throws {
        let (m, ids, _) = try model(count: 1)
        m.selection = [ids[0]]
        // A zero green would put an infinity in the kernel; `ratios(fromRebate:)` refuses
        // it and the model must stop there rather than writing a mode with no ratios.
        m.applyPickedBase([1000, 0, 1000], to: m.pickBaseTargets)
        XCTAssertNil(m.frame(ids[0])?.sidecar.develop)
        XCTAssertNotNil(m.pickBaseNote)
    }

    // MARK: (e) an undeveloped frame gets the defaults AND the base, in one sidecar

    @MainActor
    func testAnUndevelopedFramePickedGetsTheDefaultsAndTheBaseInOneSidecar() throws {
        let (m, ids, roll) = try model(count: 2)
        let id = ids[0]
        let frame = try XCTUnwrap(m.frame(id))
        XCTAssertNil(frame.sidecar.develop, "it starts undeveloped")
        let defaults = try XCTUnwrap(m.renders.defaults.initial(for: frame.sidecar))

        m.selection = [id]
        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)
        m.flushPendingSave(id)

        let onDisk = try XCTUnwrap(SidecarStore().load(for: roll.appendingPathComponent("IMG_0001.CR2")))
        let written = try XCTUnwrap(onDisk.sidecar.develop)
        XCTAssertEqual(written.stock, defaults.stock, "the default stock came with it (RIDER 1)")
        XCTAssertEqual(written.tone, defaults.tone, "and the default tone")
        XCTAssertEqual(written.autoBalance, defaults.autoBalance, "and the default autoBalance")
        XCTAssertEqual(written.base.mode, .measured, "with the measured base over the top")
        XCTAssertNotNil(written.base.ratios)

        // ONE undo, and the frame is undeveloped again: the seed and the edit are one step.
        m.undoManager.undo()
        XCTAssertNil(m.frame(id)?.sidecar.develop,
                     "the defaults commit and the base write undo together")
    }

    // MARK: the mode, the target set and the walk

    /// From the grid the dropper does not open the closeup: the loupe makes a click on a
    /// thumbnail a pick, so no change of screen is needed.
    @MainActor
    func testFromTheGridTheModeArmsWithoutOpeningTheCloseup() throws {
        let (m, ids, _) = try model(count: 3)
        m.selection = [ids[1]]
        m.showsCropOverlay = true
        XCTAssertNil(m.viewerFrameID)

        m.beginPickingBase()

        XCTAssertTrue(m.isPickingBase)
        XCTAssertTrue(m.isPickingBaseInGallery, "armed over the grid")
        XCTAssertNil(m.viewerFrameID, "and the closeup did not open")
        XCTAssertEqual(m.pickBaseTargets, [ids[1]], "the targets were snapshotted")
        XCTAssertFalse(m.showsCropOverlay, "the rectangle and the eyedropper cannot share the frame")

        m.endPickingBase()
        XCTAssertFalse(m.isPickingBase)
        XCTAssertFalse(m.isPickingBaseInGallery)
    }

    /// The gallery click writes the snapshot, not whatever is selected when it lands. The
    /// selection cannot move during the mode (the cell's own handlers are off), so this
    /// asserts the property by moving it deliberately.
    @MainActor
    func testTheGalleryClickWritesTheSnapshotRatherThanTheLiveSelection() throws {
        let (m, ids, _) = try model(count: 4)
        m.selection = [ids[0], ids[1]]
        m.beginPickingBase()
        XCTAssertTrue(m.isPickingBaseInGallery)

        m.selection = [ids[3]]
        XCTAssertEqual(m.pickBaseTargets, [ids[0], ids[1]], "still the snapshot")

        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)
        XCTAssertNotNil(m.frame(ids[0])?.sidecar.develop?.base.ratios)
        XCTAssertNotNil(m.frame(ids[1])?.sidecar.develop?.base.ratios)
        XCTAssertNil(m.frame(ids[3])?.sidecar.develop, "and not the frame selected after")
    }

    /// The closeup keeps its own behavior: armed from there, it is not the
    /// gallery mode and the frame on screen stays on screen.
    @MainActor
    func testFromTheCloseupTheModeIsNotTheGalleryMode() throws {
        let (m, ids, _) = try model(count: 3)
        m.selection = [ids[1]]
        m.openViewer(on: ids[1])
        m.beginPickingBase()
        XCTAssertTrue(m.isPickingBase)
        XCTAssertFalse(m.isPickingBaseInGallery)
        XCTAssertEqual(m.viewerFrameID, ids[1])
    }

    // MARK: (c) the cell mapping

    /// A thumbnail is drawn `scaledToFit` in a fixed 3 by 2 box, so everything that is not
    /// 3 by 2 is letterboxed and the letterbox is not film. The fitted rect is what makes a
    /// hover over the grey bar report nothing instead of a point off the end of the frame.
    func testTheCellFittedRectLetterboxesLandscapeAndPortraitCorrectly() {
        let box = CGSize(width: 300, height: 200)

        // A 3:2 landscape negative fills the box exactly.
        let full = GalleryPick.fittedRect(aspect: 1.5, in: box)
        XCTAssertEqual(full, CGRect(x: 0, y: 0, width: 300, height: 200))

        // A rotated frame is 2:3 and is pillarboxed: full height, centered.
        let turned = GalleryPick.fittedRect(aspect: 2.0 / 3.0, in: box)
        XCTAssertEqual(turned.height, 200, accuracy: 1e-9)
        XCTAssertEqual(turned.width, 200 * 2 / 3, accuracy: 1e-9)
        XCTAssertEqual(turned.midX, 150, accuracy: 1e-9, "centred in the box")

        // A wider than 3:2 frame is letterboxed: full width, centered.
        let wide = GalleryPick.fittedRect(aspect: 2.0, in: box)
        XCTAssertEqual(wide.width, 300, accuracy: 1e-9)
        XCTAssertEqual(wide.height, 150, accuracy: 1e-9)
        XCTAssertEqual(wide.midY, 100, accuracy: 1e-9)
    }

    /// The point a click turns into, for both a landscape and a rotated frame, and the
    /// no-op outside the film.
    func testTheCellPointIsNormalizedInsideTheFilmAndNilOutsideIt() {
        let box = CGSize(width: 300, height: 200)

        // Landscape, filling the box: the center is the center.
        let mid = GalleryPick.displayPoint(CGPoint(x: 150, y: 100), box: box, aspect: 1.5)
        XCTAssertEqual(mid?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid?.y ?? -1, 0.5, accuracy: 1e-9)

        // Rotated, pillarboxed to 133.33 points wide starting at x 83.33. A click at the
        // picture's own left edge is 0, and one in the bar to its left is nothing at all.
        let turnedAspect = 2.0 / 3.0
        let rect = GalleryPick.fittedRect(aspect: turnedAspect, in: box)
        let edge = GalleryPick.displayPoint(CGPoint(x: rect.minX + 0.001, y: 100),
                                            box: box, aspect: turnedAspect)
        XCTAssertEqual(edge?.x ?? -1, 0, accuracy: 1e-4)
        XCTAssertEqual(edge?.y ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(GalleryPick.displayPoint(CGPoint(x: rect.minX - 6, y: 100),
                                              box: box, aspect: turnedAspect),
                     "the pillarbox is not film, so a click there is a no-op")
        XCTAssertNil(GalleryPick.displayPoint(CGPoint(x: 150, y: 210), box: box, aspect: 1.5),
                     "and neither is anything outside the box")
    }

    /// The crop and the straighten are stripped before the pick, because the film base is
    /// by definition outside the part anybody crops to.
    func testThePickGeometryKeepsTheTurnAndDropsTheCrop() {
        let g = GeometrySettings(rotate: 90, flip: true, straightenDegrees: 2.5,
                                 crop: CropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5))
        let picked = GalleryPick.pickGeometry(g)
        XCTAssertEqual(picked.rotate, 90)
        XCTAssertTrue(picked.flip)
        XCTAssertEqual(picked.straightenDegrees, 0, accuracy: 1e-12)
        XCTAssertNil(picked.crop)
    }

    /// The square drawn inside the round loupe is the square that gets sampled, and it is
    /// scale free: the 512 pixel thumbnail and the 1400 pixel negative must give the same
    /// normalized rect, or the loupe would lie about the footprint at one of the two.
    func testTheLoupePatchRectIsTheSameAtEveryPictureResolution() {
        let display = CGPoint(x: 0.4, y: 0.6)
        for rotate in [0, 90, 180, 270] {
            let m = PickBaseMapping(rotate: rotate, flip: false)
            let small = GalleryPick.patchDisplayRect(at: display, mapping: m,
                                                     pixels: CGSize(width: 512, height: 341))
            let big = GalleryPick.patchDisplayRect(at: display, mapping: m,
                                                   pixels: CGSize(width: 1400, height: 933))
            XCTAssertEqual(small.width, big.width, accuracy: 2e-3, "rotate \(rotate)")
            XCTAssertEqual(small.height, big.height, accuracy: 2e-3, "rotate \(rotate)")
            XCTAssertTrue(small.insetBy(dx: -1e-9, dy: -1e-9).contains(display),
                          "rotate \(rotate): the square sits under the cursor")
        }
    }

    // MARK: "Pick Film Color From This Frame…", armed from a gallery cell (C2 a)

    /// The property the gallery item exists for: the frame that is SAMPLED is named by the
    /// right click and the frames that are WRITTEN are the ones already selected, and
    /// arming the mode moves neither set. `openViewer(on:)` would have failed this, which
    /// is why `beginPickingBase(sampling:targets:)` does not call it.
    @MainActor
    func testArmingFromAClickedFrameLeavesTheSelectionAndTheCursorAlone() throws {
        let (m, ids, _) = try model(count: 4)
        m.selection = [ids[0], ids[1]]
        m.anchor = ids[0]
        m.cursor = ids[0]

        m.beginPickingBase(sampling: ids[3], targets: m.selectedFrames.map(\.id))

        XCTAssertTrue(m.isPickingBase)
        XCTAssertEqual(m.viewerFrameID, ids[3], "the closeup opened on the frame that was clicked")
        XCTAssertEqual(m.selection, [ids[0], ids[1]], "and the selection did not move")
        XCTAssertEqual(m.cursor, ids[0], "nor the grid cursor")
        XCTAssertEqual(m.anchor, ids[0], "nor the shift anchor")
        XCTAssertEqual(m.pickBaseTargets, [ids[0], ids[1]], "the snapshot is the targets")
        XCTAssertFalse(m.showsCropOverlay)

        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)

        XCTAssertNotNil(m.frame(ids[0])?.sidecar.develop?.base.ratios, "the write landed on the snapshot")
        XCTAssertNotNil(m.frame(ids[1])?.sidecar.develop?.base.ratios)
        XCTAssertNil(m.frame(ids[3])?.sidecar.develop,
                     "and NOT on the frame that was merely sampled")
    }

    /// A right click with nothing selected has exactly one sensible reading.
    @MainActor
    func testArmingWithAnEmptySelectionTargetsTheClickedFrameAlone() throws {
        let (m, ids, _) = try model(count: 3)
        m.selection = []

        m.beginPickingBase(sampling: ids[2], targets: [])

        XCTAssertTrue(m.isPickingBase)
        XCTAssertEqual(m.pickBaseTargets, [ids[2]])
        XCTAssertTrue(m.selection.isEmpty, "arming still did not select anything")

        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)
        XCTAssertNotNil(m.frame(ids[2])?.sidecar.develop?.base.ratios)
        XCTAssertTrue(m.selection.isEmpty, "and neither did the write")
    }

    /// The snapshot is scoped to the mode. Leaving it hands Reuse and Clear back to what
    /// every other command acts on: the shown frame while the closeup is up, and
    /// the live selection back in the grid.
    @MainActor
    func testLeavingTheModeDropsTheSnapshot() throws {
        let (m, ids, _) = try model(count: 4)
        m.selection = [ids[0]]
        m.beginPickingBase(sampling: ids[3], targets: [ids[0]])
        XCTAssertEqual(m.pickBaseTargets, [ids[0]])

        m.endPickingBase()
        m.selection = [ids[2]]
        XCTAssertEqual(m.pickBaseTargets, [ids[3]], "in the closeup the targets are the shown frame")
        m.closeViewer()
        XCTAssertEqual(m.pickBaseTargets, [ids[2]], "in the grid they are the live selection again")
    }

    @MainActor
    func testWithNothingSelectedTheModeDoesNotArm() throws {
        let (m, _, _) = try model(count: 2)
        m.selection = []
        XCTAssertFalse(m.canPickBase)
        m.beginPickingBase()
        XCTAssertFalse(m.isPickingBase)
    }

    /// The property the whole mode rests on: the arrows walk the ROLL and the target set
    /// does not move. With one frame selected, `navigate` would have written the cursor
    /// back into the selection and silently retargeted the pick onto the frame being
    /// sampled.
    @MainActor
    func testWhilePickingTheArrowsWalkTheRollAndLeaveTheSelectionAlone() throws {
        let (m, ids, _) = try model(count: 4)
        m.selection = [ids[2]]
        // Armed from the CLOSEUP, which is where the walk exists. From the grid the mode
        // is the gallery one and there are no arrows to walk with.
        m.openViewer(on: ids[2])
        m.beginPickingBase()
        XCTAssertEqual(m.viewerFrameID, ids[2])
        XCTAssertFalse(m.isPickingBaseInGallery)

        XCTAssertTrue(m.closeupStep(.left))
        XCTAssertEqual(m.viewerFrameID, ids[1], "the closeup moved")
        XCTAssertEqual(m.selection, [ids[2]], "the selection did not")
        XCTAssertTrue(m.closeupStep(.left))
        XCTAssertEqual(m.viewerFrameID, ids[0])
        XCTAssertEqual(m.selection, [ids[2]], "still not")
        XCTAssertEqual(m.pickBaseTargets, [ids[2]], "so the pick still writes to the same frame")

        // And the frame on screen need not be one of the targets: the pick writes to the
        // selection, not to what is being looked at.
        m.applyPickedBase(goodMeans, to: m.pickBaseTargets)
        XCTAssertNotNil(m.frame(ids[2])?.sidecar.develop?.base.ratios, "the selected frame")
        XCTAssertNil(m.frame(ids[0])?.sidecar.develop, "and not the sampled one")
    }

    /// With the mode OFF the usual behavior holds: one frame selected and the arrows walk
    /// the roll with the selection following, which `SelectionThroughCloseupTests` tests.
    /// This asserts `closeupStep` does not change it.
    @MainActor
    func testWithTheModeOffTheArrowsBehaveExactlyAsBefore() throws {
        let (m, ids, _) = try model(count: 4)
        m.openViewer(on: ids[1])
        XCTAssertFalse(m.isPickingBase)
        XCTAssertTrue(m.closeupStep(.right))
        XCTAssertEqual(m.viewerFrameID, ids[2])
        XCTAssertEqual(m.selection, [ids[2]], "with one frame selected the selection follows")
    }

    /// Armed from the gallery, the pick writes to the selection it was armed over, and the
    /// header counts it. A later change of selection does not retarget it.
    @MainActor
    func testTheHeaderNamesTheCountAndTheSampledFrame() throws {
        let (m, ids, _) = try model(count: 4)
        m.selection = [ids[2], ids[3]]
        m.beginPickingBase(sampling: ids[0], targets: [ids[2], ids[3]])
        XCTAssertEqual(m.viewerFrameID, ids[0])
        XCTAssertEqual(m.pickBaseHeader, "Pick the film color for 2 frames, sampling IMG_0001")

        m.selection = [ids[3]]
        XCTAssertEqual(m.pickBaseHeader, "Pick the film color for 2 frames, sampling IMG_0001")
    }

    /// Armed in the closeup with two selected, the pick writes to the SHOWN frame alone
    /// and walking off to sample another frame keeps that one target.
    @MainActor
    func testArmedInTheCloseupThePickTargetsTheShownFrameAndKeepsItThroughTheWalk() throws {
        let (m, ids, _) = try model(count: 4)
        m.selection = [ids[2], ids[3]]
        m.openViewer(on: ids[2])
        m.beginPickingBase()
        XCTAssertEqual(m.pickBaseTargets, [ids[2]])
        m.closeupStep(.first)
        XCTAssertEqual(m.viewerFrameID, ids[0])
        XCTAssertEqual(m.pickBaseHeader, "Pick the film color for 1 frame, sampling IMG_0001")
        XCTAssertEqual(m.pickBaseTargets, [ids[2]], "the walk did not move the target")
        XCTAssertEqual(m.selection, [ids[2], ids[3]], "and the selection is untouched")
    }
}

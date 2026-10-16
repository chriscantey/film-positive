import XCTest
import AppKit
@testable import FilmPositive

/// Closeup zoom and pan. The rules live in a value, so they are asserted here with a
/// measured layout and no window: a 7D frame (5184 by 3456) in a 1000 by 600 point box on a
/// Retina screen, which fits at 0.3472.
final class CloseupZoomTests: XCTestCase {
    private let layout = CloseupZoom.Layout(viewport: CGSize(width: 1000, height: 600),
                                            imagePixels: CGSize(width: 5184, height: 3456),
                                            backingScale: 2)
    private var fit: CGFloat { 600.0 / 3456.0 * 2 }

    private func zoom() -> CloseupZoom {
        var z = CloseupZoom()
        z.update(layout: layout)
        return z
    }

    /// The image point under a viewport point, as fractions of the image.
    private func imagePoint(_ z: CloseupZoom, at a: CGPoint) -> CGPoint {
        let d = z.displaySize!
        return CGPoint(x: z.centre.x + (a.x - layout.viewport.width / 2) / d.width,
                       y: z.centre.y + (a.y - layout.viewport.height / 2) / d.height)
    }

    func testItOpensAtFitWithTheWholeFrameInTheBox() {
        let z = zoom()
        XCTAssertTrue(z.isFit)
        XCTAssertEqual(z.effectiveScale!, fit, accuracy: 1e-9)
        XCTAssertEqual(z.displaySize!.height, 600, accuracy: 1e-9, "height limited, so it fills the height")
        XCTAssertLessThanOrEqual(z.displaySize!.width, 1000)
        XCTAssertEqual(z.offset, .zero)
        XCTAssertFalse(z.canZoomOut, "nothing below fit")
        XCTAssertTrue(z.canZoomIn)
    }

    func testTheKeysClimbTheLadderAndComeBackToFit() {
        var z = zoom()
        z.zoomIn(around: nil)
        XCTAssertEqual(z.effectiveScale, 0.5, "the first rung above fit")
        z.zoomIn(around: nil)
        XCTAssertEqual(z.effectiveScale, 0.75)
        z.zoomIn(around: nil)
        XCTAssertEqual(z.effectiveScale, 1, "100 percent is a rung")
        z.zoomOut(around: nil)
        z.zoomOut(around: nil)
        XCTAssertEqual(z.effectiveScale, 0.5)
        z.zoomOut(around: nil)
        XCTAssertTrue(z.isFit, "below the lowest rung above fit is fit")
        XCTAssertEqual(z.centre, CGPoint(x: 0.5, y: 0.5), "and fit is centred")
    }

    func testFourHundredPercentIsTheTop() {
        var z = zoom()
        for _ in 0..<20 { z.zoomIn(around: nil) }
        XCTAssertEqual(z.effectiveScale, CloseupZoom.maxScale)
        XCTAssertFalse(z.canZoomIn)
        z.set(scale: 40, anchor: nil)
        XCTAssertEqual(z.effectiveScale, CloseupZoom.maxScale, "a pinch cannot pass it either")
    }

    func testTheKeysZoomAroundThePointer() {
        var z = zoom()
        let pointer = CGPoint(x: 800, y: 300)
        let before = imagePoint(z, at: pointer)
        z.zoomIn(around: pointer)
        XCTAssertEqual(z.effectiveScale, 0.5)
        let after = imagePoint(z, at: pointer)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-9, "the same part of the picture stays under the pointer")
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
        XCTAssertNotEqual(z.centre.x, 0.5, "so the view moved toward it")
    }

    func testAnEdgeStopsAtTheEdgeOfTheBox() {
        var z = zoom()
        z.set(scale: 1, anchor: CGPoint(x: 0, y: 0))
        let d = z.displaySize!
        // Anchored on the top left corner of a picture that already filled the height: no
        // band may open along the left or top edge.
        XCTAssertEqual(z.centre.x, layout.viewport.width / (2 * d.width), accuracy: 1e-9)
        XCTAssertEqual(z.centre.y, layout.viewport.height / (2 * d.height), accuracy: 1e-9)
        z.pan(by: CGSize(width: -100_000, height: -100_000))
        XCTAssertEqual(z.centre.x, 1 - layout.viewport.width / (2 * d.width), accuracy: 1e-9, "right edge on the box's right edge")
        XCTAssertEqual(z.centre.y, 1 - layout.viewport.height / (2 * d.height), accuracy: 1e-9)
    }

    func testTheDragMovesThePictureWithThePointer() {
        var z = zoom()
        z.set(scale: 1, anchor: nil)
        let before = z.offset
        z.pan(by: CGSize(width: 40, height: -25))
        XCTAssertEqual(z.offset.width - before.width, 40, accuracy: 1e-9)
        XCTAssertEqual(z.offset.height - before.height, -25, accuracy: 1e-9)
    }

    func testADragAtFitDoesNothing() {
        var z = zoom()
        z.pan(by: CGSize(width: 300, height: 300))
        XCTAssertEqual(z.centre, CGPoint(x: 0.5, y: 0.5))
    }

    func testASideSmallerThanTheBoxStaysCentred() {
        // A wide box: at 0.5 the picture is 1296 by 864 points, taller than 600 but not wider
        // than 2000, so it pans vertically and stays centered horizontally.
        var z = CloseupZoom()
        z.update(layout: .init(viewport: CGSize(width: 2000, height: 600), imagePixels: layout.imagePixels, backingScale: 2))
        z.set(scale: 0.5, anchor: CGPoint(x: 1900, y: 580))
        XCTAssertEqual(z.centre.x, 0.5)
        XCTAssertNotEqual(z.centre.y, 0.5)
        z.pan(by: CGSize(width: 500, height: 0))
        XCTAssertEqual(z.centre.x, 0.5)
    }

    func testTheSliderRunsFromFitTo100PercentAndSnapsOntoBoth() {
        var z = zoom()
        XCTAssertTrue(z.sliderEnabled)
        XCTAssertEqual(z.sliderValue, 0)
        z.setSlider(1)
        XCTAssertEqual(z.effectiveScale!, 1, accuracy: 1e-9)
        XCTAssertEqual(z.sliderValue, 1, accuracy: 1e-9)
        z.setSlider(0.97)
        XCTAssertEqual(z.effectiveScale!, 1, accuracy: 1e-9, "the right detent")
        z.setSlider(0.03)
        XCTAssertTrue(z.isFit, "the left detent is fit itself")
        z.setSlider(0.5)
        XCTAssertEqual(z.effectiveScale!, (fit * 1).squareRoot(), accuracy: 1e-9, "the middle is the geometric middle")
        z.set(scale: 3, anchor: nil)
        XCTAssertEqual(z.sliderValue, 1, "past 100 percent it rests at the right end")
    }

    func testTheSliderIsOffWhenTheFrameFitsAt100Percent() {
        var z = CloseupZoom()
        z.update(layout: .init(viewport: CGSize(width: 1000, height: 600), imagePixels: CGSize(width: 800, height: 500), backingScale: 1))
        XCTAssertFalse(z.sliderEnabled)
        z.setSlider(1)
        XCTAssertTrue(z.isFit)
    }

    func testGrowingTheWindowPastTheScaleReturnsToFit() {
        var z = zoom()
        z.set(scale: 0.5, anchor: nil)
        z.update(layout: .init(viewport: CGSize(width: 3000, height: 2000), imagePixels: layout.imagePixels, backingScale: 2))
        XCTAssertTrue(z.isFit)
    }

    func testFitFollowsAResize() {
        var z = zoom()
        z.update(layout: .init(viewport: CGSize(width: 500, height: 300), imagePixels: layout.imagePixels, backingScale: 2))
        XCTAssertTrue(z.isFit, "fit is a mode, not the number it was")
        XCTAssertEqual(z.displaySize!.height, 300, accuracy: 1e-9)
    }

    func testAFullRenderIsWantedOnlyPastTheProxysOwnPixels() {
        var z = zoom()
        XCTAssertFalse(z.needsDetail, "fit")
        z.set(scale: 0.5, anchor: nil)
        XCTAssertFalse(z.needsDetail, "one proxy pixel per screen pixel is still sharp")
        z.set(scale: 0.75, anchor: nil)
        XCTAssertTrue(z.needsDetail)
        z.reset()
        XCTAssertFalse(z.needsDetail)
    }

    func testForgettingTheLayoutGoesToFitAndGreysTheKeys() {
        var z = zoom()
        z.set(scale: 2, anchor: nil)
        z.forgetLayout()
        XCTAssertTrue(z.isFit)
        XCTAssertNil(z.layout)
        XCTAssertFalse(z.canZoomIn)
        XCTAssertFalse(z.canZoomOut)
        z.zoomIn(around: nil)
        XCTAssertTrue(z.isFit, "no layout, nothing to zoom")
    }

    func testCommandEqualsIsZoomInAndNothingElseIs() {
        XCTAssertTrue(ZoomKeyAlias.isZoomInAlias(characters: "=", modifiers: .command))
        XCTAssertFalse(ZoomKeyAlias.isZoomInAlias(characters: "=", modifiers: []), "a bare = is not a command")
        XCTAssertFalse(ZoomKeyAlias.isZoomInAlias(characters: "=", modifiers: [.command, .option]))
        XCTAssertFalse(ZoomKeyAlias.isZoomInAlias(characters: "+", modifiers: [.command, .shift]), "the menu owns the shifted key")
        XCTAssertFalse(ZoomKeyAlias.isZoomInAlias(characters: "-", modifiers: .command))
    }

    func testTwoFingersMoveThePictureWithTheFingers() {
        XCTAssertEqual(ScrollPan.delta(dx: 7, dy: -3, precise: true), CGSize(width: 7, height: -3),
                       "a trackpad reports points, passed through with the drag's sign")
        XCTAssertEqual(ScrollPan.delta(dx: 0, dy: 2, precise: false),
                       CGSize(width: 0, height: 2 * ScrollPan.lineStep), "a wheel's lines become points")
        var z = CloseupZoom()
        z.update(layout: .init(viewport: CGSize(width: 800, height: 600),
                               imagePixels: CGSize(width: 5184, height: 3456), backingScale: 1))
        let atFit = z
        z.pan(by: ScrollPan.delta(dx: 30, dy: 30, precise: true))
        XCTAssertEqual(z, atFit, "nothing moves at fit")
        z.set(scale: 1, anchor: nil)
        let before = z.offset
        z.pan(by: ScrollPan.delta(dx: -40, dy: 25, precise: true))
        XCTAssertEqual(z.offset.width - before.width, -40, accuracy: 1e-6)
        XCTAssertEqual(z.offset.height - before.height, 25, accuracy: 1e-6)
        z.pan(by: ScrollPan.delta(dx: 1e6, dy: 1e6, precise: true))
        let clamped = z.offset
        z.pan(by: ScrollPan.delta(dx: 50, dy: 50, precise: true))
        XCTAssertEqual(z.offset, clamped, "held at the edge by the drag's clamp")
    }

    // MARK: the model's gates

    @MainActor
    private func modelInCloseup() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...2 {
            try Data(repeating: 0x42, count: 32).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        Preferences.store = InMemoryPreferences()
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        XCTAssertNotNil(model.addFolder(dir))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        model.openViewer(on: model.framesInView[0].id)
        return model
    }

    @MainActor
    func testTheMenuItemsNeedAPictureOnScreen() throws {
        let model = try modelInCloseup()
        XCTAssertFalse(model.canZoomCloseup, "no layout reported yet, so nothing to zoom")
        model.closeupZoom.update(layout: layout)
        XCTAssertTrue(model.canZoomCloseupIn)
        XCTAssertFalse(model.canZoomCloseupOut)
        XCTAssertFalse(model.canZoomCloseupToFit)
        model.closeupPointer = CGPoint(x: 800, y: 300)
        model.zoomCloseupIn()
        XCTAssertEqual(model.closeupZoom.effectiveScale, 0.5)
        XCTAssertNotEqual(model.closeupZoom.centre.x, 0.5, "the model hands the pointer in as the anchor")
        XCTAssertTrue(model.canZoomCloseupOut)
        XCTAssertTrue(model.canZoomCloseupToFit)
        model.zoomCloseupToFit()
        XCTAssertTrue(model.closeupZoom.isFit)
    }

    @MainActor
    func testTheCropRectangleAndTheEyedropperTakeTheZoomAway() throws {
        let model = try modelInCloseup()
        model.closeupZoom.update(layout: layout)
        model.showsCropOverlay = true
        XCTAssertFalse(model.canZoomCloseup, "the rectangle keeps its own drags")
        model.zoomCloseupIn()
        XCTAssertTrue(model.closeupZoom.isFit)
        model.showsCropOverlay = false
        model.isPickingBase = true
        XCTAssertFalse(model.canZoomCloseup, "the eyedropper aims at the whole negative")
    }

    @MainActor
    func testLeavingTheCloseupForgetsTheZoom() throws {
        let model = try modelInCloseup()
        model.closeupZoom.update(layout: layout)
        model.zoomCloseupIn()
        model.closeViewer()
        XCTAssertTrue(model.closeupZoom.isFit)
        XCTAssertNil(model.closeupZoom.layout)
        XCTAssertFalse(model.canZoomCloseup)
    }

    /// The view pieces that are not a value: a frame step resets, the monitor comes and
    /// goes with the closeup, and the zoomed picture sits in an overlay so its size never
    /// reaches the pane's layout.
    func testTheCloseupWiresTheZoom() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositive/UI/Viewer/ViewerView.swift")
        let s = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(s.contains("zoomAlias.install"))
        XCTAssertTrue(s.contains("zoomAlias.remove()"))
        XCTAssertTrue(s.contains("model.closeupZoom.reset()"), "a frame step goes back to fit")
        XCTAssertTrue(s.contains(".clipped()"))
    }
}

import XCTest

/// Grabbing the straighten slider shows the crop rectangle, because the live turn and the
/// thirds grid draw in that overlay and without it only the number moves.
final class StraightenOverlayTests: XCTestCase {
    func testTheFirstTouchShowsTheCropRectangle() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Crop/CropPane.swift")
        let slider = try XCTUnwrap(s.range(of: "Slider(value: straightenBinding"))
        let tail = String(s[slider.lowerBound...].prefix(600))
        XCTAssertTrue(tail.contains("if editing && !model.showsCropOverlay { model.toggleCropOverlay() }"))
    }
}

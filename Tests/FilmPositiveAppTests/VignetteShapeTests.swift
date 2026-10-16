import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The vignette is an oval fitted to the (cropped) frame it is given, right darkens the
/// edges, left lightens them. Rendered on flat grey frames of two shapes, so the shape of
/// the falloff is a matter of reading pixels at equal elliptical distances.
final class VignetteShapeTests: XCTestCase {
    static func grey(_ w: Int, _ h: Int) -> DecodedFrame {
        DecodedFrame(width: w, height: h, pixels: [UInt16](repeating: UInt16(0.5 * 65535), count: w * h * 3))
    }

    static let control = EnhanceControl.all.first { $0.id == "vignette" }!

    /// `v` is the SLIDER's value, as the person sees it.
    func render(_ f: DecodedFrame, _ v: Double) throws -> (Int, Int) -> Int {
        let s = Self.control.setting(EnhanceSettings(), to: v)
        let o = try CoreImageEnhance().apply(f, settings: s)
        return { x, y in Int(o.pixels[(y * o.width + x) * 3 + 1]) }
    }

    func testTheFalloffIsAnOvalMatchedToTheFrame() throws {
        for (w, h) in [(1200, 600), (600, 900)] {
            let g = try render(Self.grey(w, h), 1)
            let left = g(1, h / 2), top = g(w / 2, 1)
            XCTAssertEqual(Double(left), Double(top), accuracy: Double(top) * 0.02,
                           "\(w)x\(h): the middle of a long edge and of a short edge match (\(left), \(top))")
            let halfX = g(w / 4, h / 2), halfY = g(w / 2, h / 4)
            XCTAssertEqual(Double(halfX), Double(halfY), accuracy: Double(halfY) * 0.01,
                           "\(w)x\(h): halfway out along either axis match")
        }
    }

    func testRightDarkensAndLeftLightens() throws {
        let f = Self.grey(1200, 800)
        let centre = 32767
        let dark = try render(f, 0.6), light = try render(f, -0.6)
        XCTAssertLessThan(dark(2, 2), centre - 8000, "right darkens the corners")
        XCTAssertGreaterThan(light(2, 2), centre + 8000, "left lightens them")
        XCTAssertEqual(dark(600, 400), centre, accuracy: 300, "the centre stays put")
        XCTAssertEqual(light(600, 400), centre, accuracy: 300)
        let stronger = try render(f, 1)
        XCTAssertLessThan(stronger(2, 2), dark(2, 2), "more is darker")
    }

    /// A positive stored value means lighter edges, and the slider shows it on the left, so a
    /// saved value renders as it always has.
    func testAStoredPositiveValueStillLightens() throws {
        var saved = EnhanceSettings(); saved.vignette = 0.6
        let o = try CoreImageEnhance().apply(Self.grey(1200, 800), settings: saved)
        XCTAssertGreaterThan(Int(o.pixels[(2 * 1200 + 2) * 3 + 1]), 32767 + 8000, "stored +0.6 still lightens")
        XCTAssertEqual(Self.control.value(in: saved), -0.6, "and reads as -0.6 on the slider")
        XCTAssertEqual(Self.control.setting(EnhanceSettings(), to: 0.4).vignette, -0.4, "right on the slider stores negative")
    }
}

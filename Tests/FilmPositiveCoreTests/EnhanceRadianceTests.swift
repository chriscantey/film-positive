import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Radiance in the chain beside Shadows and Highlights. Each slider keeps its own budget, so
/// full Radiance never takes away another slider's travel, and both halves of Radiance move
/// the frame. If Radiance shared one clamped expression with Shadows and Highlights, the first
/// two tests would compare byte-identical renders. The operator's own properties are in
/// `RadianceOperatorTests`.
///
/// The patches are wide on purpose: each patch's center is several base radii from its
/// neighbours, so it reads the tone table and not the detail term.
final class EnhanceRadianceTests: XCTestCase {
    static let patches: [(name: String, v: Int)] = [
        ("black", 8), ("shadow", 48), ("midgrey", 128), ("highlight", 208), ("white", 247),
    ]
    static let patchSide = 200
    static var W: Int { patchSide * patches.count }
    static var H: Int { patchSide }

    static let base: DecodedFrame = {
        var px = [UInt16](repeating: 0, count: W * H * 3)
        for (i, p) in patches.enumerated() {
            for y in 0..<H {
                for x in (i * patchSide)..<((i + 1) * patchSide) {
                    let o = (y * W + x) * 3
                    let c = UInt16(p.v * 257)
                    px[o] = c; px[o + 1] = c; px[o + 2] = c
                }
            }
        }
        return DecodedFrame(width: W, height: H, pixels: px)
    }()

    let stage = CoreImageEnhance()

    /// The center of a patch, in 8-bit units, well away from any edge the blur can reach.
    func patch(_ name: String, _ f: DecodedFrame) -> Double {
        let i = Self.patches.firstIndex { $0.name == name }!
        let x = i * Self.patchSide + Self.patchSide / 2, y = f.height / 2
        return Double(f.pixels[(y * f.width + x) * 3]) / 257.0
    }

    func render(_ f: (inout EnhanceSettings) -> Void) throws -> DecodedFrame {
        var p = EnhanceSettings.identity; f(&p)
        return try stage.apply(Self.base, settings: p)
    }

    /// The Shadows slider must keep its own authority whatever Radiance is doing. A shared
    /// `shadows * 0.8 + radiance * 0.5` hits the clamp at Shadows 0.625, so 0.625 and 1.0
    /// produce the same picture.
    func testShadowsKeepTheirAuthorityAtFullRadiance() throws {
        let low = try render { $0.radiance = 1.0; $0.shadows = 0.625 }
        let high = try render { $0.radiance = 1.0; $0.shadows = 1.0 }
        XCTAssertGreaterThan(patch("shadow", high), patch("shadow", low) + 1.0,
                             "Shadows 1.0 must lift further than Shadows 0.625 with Radiance at full")
    }

    /// The same defect at the other end: `1 + highlights * 0.9 - radiance * 0.35` clamps
    /// to 0 for every Highlights value below about -0.72 once Radiance is at 1.0.
    func testHighlightsKeepTheirAuthorityAtFullRadiance() throws {
        let low = try render { $0.radiance = 1.0; $0.highlights = -0.8 }
        let high = try render { $0.radiance = 1.0; $0.highlights = -1.0 }
        XCTAssertLessThan(patch("highlight", high), patch("highlight", low) - 0.5,
                          "Highlights -1.0 must pull further than -0.8 with Radiance at full")
    }

    /// The negative half changes the frame and deepens the shadows. Fails if negative values
    /// are clamped to 0 anywhere on the way to the operator.
    func testNegativeRadianceIsNotANoOp() throws {
        let down = try render { $0.radiance = -1.0 }
        XCTAssertNotEqual(down.pixels, Self.base.pixels, "negative Radiance must change the frame")
        XCTAssertLessThan(patch("shadow", down), patch("shadow", Self.base) - 1.0,
                          "negative Radiance darkens locally dark regions")
    }

    /// Both arms travel both ways: the shadow patch lifts at +1 and drops at -1, and the
    /// near-white patch is pulled in at +1 and pushed out at -1, the mirror of the shadow arm.
    func testBothArmsMoveInBothDirections() throws {
        let b = patch("shadow", Self.base)
        let up = try render { $0.radiance = 1.0 }
        let down = try render { $0.radiance = -1.0 }
        XCTAssertGreaterThan(patch("shadow", up), b + 1.0, "positive Radiance lifts")
        XCTAssertLessThan(patch("shadow", down), b - 1.0, "negative Radiance drops")

        let wb = patch("white", Self.base)
        XCTAssertLessThan(patch("white", up), wb - 1.0, "positive Radiance pulls the white patch in")
        XCTAssertGreaterThan(patch("white", down), wb + 1.0, "negative Radiance pushes it out")
    }
}

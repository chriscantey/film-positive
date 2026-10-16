import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Highlights is two controls on one slider. The positive half is a tone curve term: at
/// 0.12 it moves a real frame's p90 from 0.7525 to 0.8295 at full travel, where 0.25
/// reaches 0.9124. The negative half drives `inputHighlightAmount`, and with a floor of 0.1,
/// below Apple's own recommended slider floor of 0.3, it finishes its useful work in the
/// first tenth of the slider: clipped white goes 2.96 percent to zero by -0.1 and the
/// remaining ninety percent of the travel is a global darkener.
final class EnhanceHighlightsTests: XCTestCase {
    static let rampFrame: DecodedFrame = {
        var px = [UInt16](repeating: 0, count: 256 * 4 * 3)
        for y in 0..<4 {
            for x in 0..<256 {
                let c = UInt16(x * 257)
                let o = (y * 256 + x) * 3
                px[o] = c; px[o + 1] = c; px[o + 2] = c
            }
        }
        return DecodedFrame(width: 256, height: 4, pixels: px)
    }()

    /// The patch frame EnhanceTests uses, at the same values, so the margin on its
    /// highlights assertion (line 83, highlights -0.9 pulls the highlight patch down by
    /// more than 2 units of 255) is checked here too and against a stated number rather
    /// than inherited.
    static let patchFrame: DecodedFrame = {
        let values = [8, 48, 128, 208, 247]
        let w = 40 * values.count, h = 40
        var px = [UInt16](repeating: 0, count: w * h * 3)
        for (i, v) in values.enumerated() {
            for y in 0..<h {
                for x in (i * 40)..<((i + 1) * 40) {
                    let o = (y * w + x) * 3
                    let c = UInt16(v * 257)
                    px[o] = c; px[o + 1] = c; px[o + 2] = c
                }
            }
        }
        return DecodedFrame(width: w, height: h, pixels: px)
    }()

    let stage = CoreImageEnhance()

    func ramp(_ f: (inout EnhanceSettings) -> Void) throws -> [Double] {
        var p = EnhanceSettings.identity; f(&p)
        let out = try stage.apply(Self.rampFrame, settings: p)
        return (0..<256).map { Double(out.pixels[(2 * 256 + $0) * 3]) / 65535.0 }
    }

    /// The highlight patch center, in 8-bit units.
    func highlightPatch(_ f: (inout EnhanceSettings) -> Void) throws -> Double {
        var p = EnhanceSettings.identity; f(&p)
        let out = try stage.apply(Self.patchFrame, settings: p)
        let x = 3 * 40 + 20, y = out.height / 2
        return Double(out.pixels[(y * out.width + x) * 3]) / 257.0
    }

    /// The tone curve puts the three quarter point at 0.75 + 0.25 * 0.7 = 0.925 at full
    /// slider. A coefficient of 0.12 reaches 0.834, so the bound separates them.
    func testPositiveHighlightsReachFurther() throws {
        let up = try ramp { $0.highlights = 1.0 }
        XCTAssertGreaterThan(up[192], 0.88, "highlights +1 took the three quarter tone to \(up[192])")
        let half = try ramp { $0.highlights = 0.5 }
        XCTAssertGreaterThan(up[192], half[192], "the top half of the slider must still do something")
        XCTAssertGreaterThan(half[192], 192.0 / 255.0, "highlights + must push the three quarter tone up")
        for i in 1..<256 {
            XCTAssertGreaterThanOrEqual(up[i], up[i - 1] - 1e-9, "the curve must stay monotone at step \(i)")
        }
    }

    /// The recovery still works, and it still completes early, which is the filter's own
    /// shape and not something the floor changes. What the floor changes is how much of
    /// the frame goes with it.
    func testNegativeHighlightsStillRecoverAndKeepTravel() throws {
        let base = try highlightPatch { _ in }
        let gentle = try highlightPatch { $0.highlights = -0.3 }
        let full = try highlightPatch { $0.highlights = -1.0 }
        XCTAssertLessThan(gentle, base - 2, "highlights -0.3 must pull the highlight patch down")
        XCTAssertLessThan(full, gentle, "the rest of the travel must still move it")
    }

    /// EnhanceTests line 83's assertion, with its margin named. The softer floor makes the
    /// drop smaller, so this is the one that could have broken quietly.
    func testTheEnhanceTestsMarginStillHolds() throws {
        let base = try highlightPatch { _ in }
        let pulled = try highlightPatch { $0.highlights = -0.9 }
        let margin = base - pulled
        XCTAssertGreaterThan(margin, 2.0, "highlights -0.9 pulled the highlight patch down by only \(margin) of 255")
    }

    /// The negative direction is a highlight control, so it must not drag the midtone down
    /// with it.
    func testNegativeHighlightsLeaveTheMidtoneAlone() throws {
        let out = try ramp { $0.highlights = -1.0 }
        XCTAssertGreaterThan(out[128], 0.40, "highlights -1 took the midtone to \(out[128])")
        XCTAssertLessThan(out[192], 192.0 / 255.0, "highlights -1 must still lower the three quarter tone")
    }
}

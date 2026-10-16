import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// The enhance chain must render the same picture at every scale, because preview and
/// export share one chain (`EnhanceGraph.swift`). A spatial radius that is a constant number
/// of pixels makes the local tone operator see a four times larger relative neighborhood on
/// a drag preview than on the export, so the app shows one picture while saving another.
///
/// Two independent guards, both with a verified failing direction: making
/// `CoreImageEnhance.radius` return constant radii fails both (see the measured numbers
/// beside each assertion).
final class EnhanceScaleTests: XCTestCase {
    /// A frame with real structure, because a flat patch cannot tell a 3 px radius from a
    /// 12 px one. Hard-edged dark blocks on a bright ground are exactly where a local tone
    /// operator's neighbourhood size shows: that is where the halo and the crushing live.
    /// Deterministic, no randomness, so a failure is reproducible.
    static func structured(_ side: Int) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                // Diagonal gradient ground, mid to bright.
                var v = 0.35 + 0.55 * (Double(x + y) / Double(2 * side - 2))
                // A grid of dark squares, each 1/16 of the side, on that ground.
                let cell = max(1, side / 16)
                if ((x / cell) + (y / cell)) % 3 == 0 { v *= 0.12 }
                // A fine ramp inside each cell so there is detail below the block scale.
                v += 0.03 * (Double(x % cell) / Double(cell))
                let c = UInt16(max(0, min(65535, (v * 65535).rounded())))
                let o = (y * side + x) * 3
                px[o] = c
                px[o + 1] = UInt16(Double(c) * 0.94)
                px[o + 2] = UInt16(Double(c) * 0.86)
            }
        }
        return DecodedFrame(width: side, height: side, pixels: px)
    }

    let stage = CoreImageEnhance()

    func meanAbsDiff(_ a: DecodedFrame, _ b: DecodedFrame) -> Double {
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        var sum = 0.0
        for i in 0..<a.pixels.count { sum += abs(Double(a.pixels[i]) - Double(b.pixels[i])) }
        return sum / Double(a.pixels.count) / 257.0
    }

    /// Fraction of pixels whose every channel is pure black.
    func clippedBlack(_ f: DecodedFrame) -> Double {
        var n = 0
        var i = 0
        while i < f.pixels.count {
            if f.pixels[i] == 0 && f.pixels[i + 1] == 0 && f.pixels[i + 2] == 0 { n += 1 }
            i += 3
        }
        return Double(n) / Double(f.width * f.height)
    }

    /// Render at full then halve, against halve then render. Downsampling does not commute
    /// with a non-linear curve, so some divergence is expected from the resampling alone,
    /// measured at 0.004 units of 255 with a radius-free curve. With the radii constant the
    /// whole chain diverges by 1.167 units on a real fixture. The bound here is stated in
    /// the same units and is checked in the failing direction against constant radii.
    func testRenderScaleCommutesWithHalving() throws {
        var p = EnhanceSettings.identity
        p.radiance = 1.0
        p.shadows = 0.6
        p.definition = 0.5

        let full = Self.structured(1024)
        let renderThenHalve = Geometry.halve(try stage.apply(full, settings: p))
        let halveThenRender = try stage.apply(Geometry.halve(full), settings: p)
        let delta = meanAbsDiff(renderThenHalve, halveThenRender)

        // Measured: 0.271 with scaled radii, 6.304 with constant radii. With Radiance as
        // the guided filter tone map, 0.270.
        XCTAssertLessThan(delta, 0.35, "render-then-halve differs from halve-then-render by \(delta) units of 255")
    }

    /// The same settings at two scales must newly clip the same proportion of the frame to
    /// black, each measured against its own scale's identity. The radius-free tone curve
    /// agrees across scales to within 0.3 percentage points. With constant radii every
    /// radius-bearing control does not, and the drag preview crushes 2.6x more black than
    /// the export.
    func testNewlyClippedBlackAgreesAcrossScales() throws {
        var p = EnhanceSettings.identity
        p.radiance = 1.0
        p.shadows = -1.0

        let full = Self.structured(1024)
        let half = Geometry.halve(full)
        let fullDelta = clippedBlack(try stage.apply(full, settings: p)) - clippedBlack(full)
        let halfDelta = clippedBlack(try stage.apply(half, settings: p)) - clippedBlack(half)
        let gap = abs(fullDelta - halfDelta) * 100

        // Measured: 0.578 pp with scaled radii, 3.425 pp with constant radii. With Radiance
        // as the guided filter tone map, 0.065 pp.
        XCTAssertLessThan(gap, 1.0, "newly clipped black differs by \(gap) percentage points between scales")
    }

    /// The floor exists so a small frame never asks for a sub-sampling-limit radius, and
    /// the scaling is otherwise exactly proportional. Asserted directly rather than only
    /// through a render, because the render tests above would also pass if the radius were
    /// pinned at the floor everywhere.
    func testRadiusScalesWithTheFrameAndHasAFloor() {
        let fullExtent = CGRect(x: 0, y: 0, width: 5202, height: 3468)
        XCTAssertEqual(CoreImageEnhance.radius(12.0, fullExtent), 12.0, accuracy: 0.001)
        let previewExtent = CGRect(x: 0, y: 0, width: 1300, height: 867)
        XCTAssertEqual(CoreImageEnhance.radius(12.0, previewExtent), 12.0 * 1300 / 5202, accuracy: 0.001)
        let tiny = CGRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertEqual(CoreImageEnhance.radius(2.0, tiny), 0.5, accuracy: 0.001)
    }
}

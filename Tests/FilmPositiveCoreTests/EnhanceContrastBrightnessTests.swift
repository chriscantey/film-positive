import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Contrast and Brightness as `CIColorControls` in a linear-light working space pivot
/// Contrast at sRGB 0.735 and make Brightness add a constant in linear light. Measured on a
/// real frame: Contrast +1 crushes 19 to 30 percent of the pixels to pure black and
/// Brightness +1 strips 52 percent of the chroma and lifts the black floor to 0.59.
///
/// Every assertion here fails on that mapping, which is what makes them guards rather
/// than descriptions.
final class EnhanceContrastBrightnessTests: XCTestCase {
    static let side = 384

    /// A frame with a full tonal spread and real color, so both clipping and chroma are
    /// measurable. Nothing starts at pure black or pure white, so any pixel on a rail
    /// afterwards was put there by the slider.
    static let base: DecodedFrame = {
        var px = [UInt16](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let t = Double(x) / Double(side - 1)
                let v = 0.02 + 0.96 * t
                let o = (y * side + x) * 3
                // A color that varies down the frame, so chroma is not a single number.
                let warm = 0.10 * (Double(y) / Double(side - 1))
                px[o] = UInt16(max(0, min(65535, ((v + warm * v) * 65535).rounded())))
                px[o + 1] = UInt16(max(0, min(65535, (v * 65535).rounded())))
                px[o + 2] = UInt16(max(0, min(65535, ((v - warm * v) * 65535).rounded())))
            }
        }
        return DecodedFrame(width: side, height: side, pixels: px)
    }()

    /// A 256 step grey ramp, one row, for reading the transfer directly.
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

    let stage = CoreImageEnhance()

    func render(_ f: (inout EnhanceSettings) -> Void) throws -> DecodedFrame {
        var p = EnhanceSettings.identity; f(&p)
        return try stage.apply(Self.base, settings: p)
    }

    func ramp(_ f: (inout EnhanceSettings) -> Void) throws -> [Double] {
        var p = EnhanceSettings.identity; f(&p)
        let out = try stage.apply(Self.rampFrame, settings: p)
        return (0..<256).map { Double(out.pixels[(2 * 256 + $0) * 3]) / 65535.0 }
    }

    func clippedBlack(_ f: DecodedFrame) -> Double {
        var n = 0, i = 0
        while i < f.pixels.count {
            if f.pixels[i] == 0 && f.pixels[i + 1] == 0 && f.pixels[i + 2] == 0 { n += 1 }
            i += 3
        }
        return Double(n) / Double(f.width * f.height) * 100
    }

    func clippedWhite(_ f: DecodedFrame) -> Double {
        var n = 0, i = 0
        while i < f.pixels.count {
            if f.pixels[i] == 65535 && f.pixels[i + 1] == 65535 && f.pixels[i + 2] == 65535 { n += 1 }
            i += 3
        }
        return Double(n) / Double(f.width * f.height) * 100
    }

    /// Mean of (max channel - min channel), a cheap stand-in for chroma that needs no
    /// color conversion and moves in the same direction as C*.
    func meanSpread(_ f: DecodedFrame) -> Double {
        var sum = 0.0, i = 0
        while i < f.pixels.count {
            let r = Double(f.pixels[i]), g = Double(f.pixels[i + 1]), b = Double(f.pixels[i + 2])
            sum += (max(r, max(g, b)) - min(r, min(g, b))) / 257.0
            i += 3
        }
        return sum / Double(f.width * f.height)
    }

    /// Contrast +1 clips under one percent of a known frame to black. A linear-light pivot
    /// puts 19 to 30 percent of a real frame there.
    func testContrastPlusOneBarelyClipsToBlack() throws {
        XCTAssertEqual(clippedBlack(Self.base), 0, accuracy: 0.0001, "the fixture must start with no black")
        let hot = try render { $0.contrast = 1.0 }
        XCTAssertLessThan(clippedBlack(hot), 1.0, "contrast +1 clipped \(clippedBlack(hot)) percent to black")
    }

    /// And the other direction: a linear-light contrast -1 turns the darkest one percent of
    /// a frame into 54 percent grey and removes 63 percent of the chroma. A curve pinned at
    /// both ends cannot do either.
    func testContrastMinusOneDoesNotFlattenTheFrameIntoGrey() throws {
        let flat = try render { $0.contrast = -1.0 }
        let r = meanSpread(flat) / meanSpread(Self.base)
        XCTAssertGreaterThan(r, 0.60, "contrast -1 kept only \(r) of the colour spread")
        let out = try ramp { $0.contrast = -1.0 }
        XCTAssertLessThan(out[0], 0.02, "contrast -1 lifted black to \(out[0])")
    }

    /// The pivot is where the name says it is. A linear-light pivot sits at sRGB 0.735.
    func testContrastPivotsAtDisplayReferredHalf() throws {
        let up = try ramp { $0.contrast = 1.0 }
        let down = try ramp { $0.contrast = -1.0 }
        XCTAssertEqual(up[128], 128.0 / 255.0, accuracy: 0.01, "contrast + moved the midpoint")
        XCTAssertEqual(down[128], 128.0 / 255.0, accuracy: 0.01, "contrast - moved the midpoint")
        XCTAssertLessThan(up[64], 64.0 / 255.0 - 0.02, "contrast + must pull the quarter tone down")
        XCTAssertGreaterThan(up[192], 192.0 / 255.0 + 0.02, "contrast + must push the three quarter tone up")
        XCTAssertGreaterThan(down[64], 64.0 / 255.0 + 0.02, "contrast - must lift the quarter tone")
        XCTAssertLessThan(down[192], 192.0 / 255.0 - 0.02, "contrast - must lower the three quarter tone")
    }

    /// Brightness as a gamma pins both ends, so it cannot rail the frame, and it keeps the
    /// color. A constant added in linear light lifts the black floor to 0.59 and removes 52
    /// percent of the chroma at +1.
    func testBrightnessPinsBothEndsAndKeepsTheColour() throws {
        let up = try render { $0.brightness = 1.0 }
        XCTAssertLessThan(clippedWhite(up), 1.0, "brightness +1 clipped \(clippedWhite(up)) percent to white")
        let r = meanSpread(up) / meanSpread(Self.base)
        XCTAssertGreaterThan(r, 0.60, "brightness +1 kept only \(r) of the colour spread")

        let out = try ramp { $0.brightness = 1.0 }
        XCTAssertEqual(out[0], 0, accuracy: 0.004, "gamma must leave black at black, got \(out[0])")
        XCTAssertEqual(out[255], 1, accuracy: 0.004, "gamma must leave white at white, got \(out[255])")
        XCTAssertGreaterThan(out[128], 128.0 / 255.0 + 0.05, "brightness + must lift the midtone")

        let down = try ramp { $0.brightness = -1.0 }
        XCTAssertEqual(down[0], 0, accuracy: 0.004)
        XCTAssertEqual(down[255], 1, accuracy: 0.004)
        XCTAssertLessThan(down[128], 128.0 / 255.0 - 0.05, "brightness - must lower the midtone")
    }

    /// The two halves are inverses, which is what `pow(0.7, brightness)` buys and what a
    /// linear interpolation between 0.7 and 1.43 would not. Checked in LINEAR light,
    /// because that is the space CIGammaAdjust runs in: the app never sets
    /// `workingColorSpace`, so Core Image's linear extended sRGB default applies and the
    /// power law is `linear ** power`, not `encoded ** power`.
    func testBrightnessIsSymmetricAboutIdentity() throws {
        func toLinear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let up = try ramp { $0.brightness = 1.0 }
        let down = try ramp { $0.brightness = -1.0 }
        for i in stride(from: 32, to: 250, by: 16) {
            // linear(up) is L ** 0.7 and linear(down) is L ** (1 / 0.7), so each is the
            // other's inverse about identity and undoing either recovers the input.
            let l = toLinear(Double(i) / 255.0)
            XCTAssertEqual(pow(toLinear(up[i]), 1 / 0.7), l, accuracy: 0.01, "the + half is not a 0.7 gamma at step \(i)")
            XCTAssertEqual(pow(toLinear(down[i]), 0.7), l, accuracy: 0.01, "the - half does not undo the + half at step \(i)")
        }
    }
}

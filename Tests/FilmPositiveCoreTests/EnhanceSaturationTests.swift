import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Spending the whole of Apple's own recommended slider for `CIColorControls` (0 to 2) in
/// one travel with no gamut handling makes the top of the slider add color and destroy
/// highlight at the same time. The positive side is eased to 0.6. The negative side is
/// not, because -1 has to stay true monochrome.
final class EnhanceSaturationTests: XCTestCase {
    static let side = 256

    /// A frame carrying both a muted and a vivid population, plus enough bright color to
    /// put the gamut boundary within reach of the slider. Nothing starts clipped.
    static let base: DecodedFrame = {
        var px = [UInt16](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let t = Double(x) / Double(side - 1)
                let band = y * 4 / side // four horizontal bands
                let v = 0.15 + 0.75 * t
                var r = v, g = v, b = v
                switch band {
                case 0: r = v * 1.08; b = v * 0.92        // muted warm
                case 1: r = v * 1.30; g = v * 0.85; b = v * 0.80 // vivid red
                case 2: g = v * 1.20; r = v * 0.88; b = v * 0.85 // vivid green
                default: b = v * 1.25; r = v * 0.82; g = v * 0.90 // vivid blue
                }
                let o = (y * side + x) * 3
                px[o] = UInt16(max(0, min(65000, (r * 65535).rounded())))
                px[o + 1] = UInt16(max(0, min(65000, (g * 65535).rounded())))
                px[o + 2] = UInt16(max(0, min(65000, (b * 65535).rounded())))
            }
        }
        return DecodedFrame(width: side, height: side, pixels: px)
    }()

    let stage = CoreImageEnhance()

    func render(_ f: (inout EnhanceSettings) -> Void) throws -> DecodedFrame {
        var p = EnhanceSettings.identity; f(&p)
        return try stage.apply(Self.base, settings: p)
    }

    func meanSpread(_ f: DecodedFrame) -> Double {
        var sum = 0.0, i = 0
        while i < f.pixels.count {
            let r = Double(f.pixels[i]), g = Double(f.pixels[i + 1]), b = Double(f.pixels[i + 2])
            sum += (max(r, max(g, b)) - min(r, min(g, b))) / 257.0
            i += 3
        }
        return sum / Double(f.width * f.height)
    }

    /// Percentage of pixels with at least one channel on the white rail. Channel-wise
    /// rather than all-three, because that is how a saturation push burns a highlight: it
    /// pins one channel and leaves the others behind.
    func clippedChannels(_ f: DecodedFrame) -> Double {
        var n = 0, i = 0
        while i < f.pixels.count {
            if f.pixels[i] == 65535 || f.pixels[i + 1] == 65535 || f.pixels[i + 2] == 65535 { n += 1 }
            i += 3
        }
        return Double(n) / Double(f.width * f.height) * 100
    }

    /// The easing is real and is measured against what the old coefficient would do, which
    /// is exactly the value the negative side still uses. Saturation +1 must now add less
    /// chroma than saturation +1 used to, and the stand-in for "used to" is the untouched
    /// mapping at the same nominal amount.
    func testThePositiveSideIsEased() throws {
        let base = meanSpread(Self.base)
        let eased = meanSpread(try render { $0.saturation = 1.0 })
        // 1 + 1.0 * 0.6 = 1.6, and the un-eased mapping is 1 + 1.0 = 2.0. A saturation of
        // 0.6 under the eased mapping reaches 1.36, so the ordering below is only
        // satisfiable if the coefficient is actually applied.
        let atSixTenths = meanSpread(try render { $0.saturation = 0.6 })
        XCTAssertGreaterThan(eased, base, "saturation + must still add chroma")
        XCTAssertGreaterThan(eased, atSixTenths, "the slider must still have travel at the top")
        // Measured: 0.547 eased, 0.960 un-eased. This is the guard that separates
        // the two mappings cleanly.
        let gain = (eased - base) / base
        XCTAssertLessThan(gain, 0.75, "saturation +1 added \(gain) of the frame's own chroma back")
    }

    /// The clipping the slider induces on its own. On a real frame the un-eased mapping
    /// takes 2.96 percent to 7.83 and 5.98 to 16.81.
    func testSaturationDoesNotBurnTheHighlight() throws {
        XCTAssertEqual(clippedChannels(Self.base), 0, accuracy: 0.0001, "the fixture must start unclipped")
        let hot = try render { $0.saturation = 1.0 }
        // Measured over this fixture: 16.80 percent eased, 20.996 un-eased. The
        // separation is narrower here than the 2.96 to 7.83 measured on a
        // real frame, because this fixture is deliberately pressed against the gamut wall
        // to begin with and a real photograph is not. The chroma assertion above is the
        // sharper of the two guards; this one bounds the damage.
        XCTAssertLessThan(clippedChannels(hot), 19.0, "saturation +1 clipped \(clippedChannels(hot)) percent of channels")
    }

    /// The negative side is untouched on purpose. -1 must be exactly monochrome or the
    /// silver and overcast looks stop being black and white.
    func testMinusOneIsStillTrueMonochrome() throws {
        let mono = try render { $0.saturation = -1.0 }
        var worst = 0
        var i = 0
        while i < mono.pixels.count {
            let r = Int(mono.pixels[i]), g = Int(mono.pixels[i + 1]), b = Int(mono.pixels[i + 2])
            worst = max(worst, max(r, max(g, b)) - min(r, min(g, b)))
            i += 3
        }
        XCTAssertLessThanOrEqual(worst, 257, "the widest channel spread left was \(worst) of 65535")
    }

    /// And the negative half is still linear all the way down, so -0.5 sits halfway.
    func testTheNegativeSideIsNotEased() throws {
        let base = meanSpread(Self.base)
        let half = meanSpread(try render { $0.saturation = -0.5 })
        XCTAssertEqual(half / base, 0.5, accuracy: 0.06, "saturation -0.5 left \(half / base) of the chroma")
    }
}

import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Glow and Halation: light spilling around the highlights, rendered on a
/// synthetic frame with one bright square on a dark ground, so what spread where is a
/// matter of reading three pixels.
final class GlowHalationTests: XCTestCase {

    static let side = 1024
    static let square = 480..<544
    static let ground = UInt16(0.2 * 65535)

    /// A dark grey frame with a white square in the middle.
    static func frame() -> DecodedFrame {
        var px = [UInt16](repeating: ground, count: side * side * 3)
        for y in square { for x in square { let i = (y * side + x) * 3; px[i] = 65535; px[i + 1] = 65535; px[i + 2] = 65535 } }
        return DecodedFrame(width: side, height: side, pixels: px)
    }

    static func rgb(_ f: DecodedFrame, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * f.width + x) * 3
        return (Int(f.pixels[i]), Int(f.pixels[i + 1]), Int(f.pixels[i + 2]))
    }

    func render(_ s: EnhanceSettings) throws -> DecodedFrame {
        try CoreImageEnhance().apply(Self.frame(), settings: s)
    }

    /// Just outside the square's right edge, and a corner far from it.
    let ring = (x: 550, y: 512)
    let far = (x: 40, y: 40)

    func testBothAtZeroAreTheIdentity() throws {
        var s = EnhanceSettings()
        s.glow = 0; s.halation = 0; s.softness = 0
        XCTAssertTrue(s.isIdentity)
        XCTAssertEqual(try render(s).pixels, Self.frame().pixels, "0 is identity, byte for byte")
    }

    /// A negative value means nothing, so the chain clamps it to 0: the same frame as the
    /// same settings without it, byte for byte.
    func testANegativeValueRendersAsZero() throws {
        var base = EnhanceSettings()
        base.vignette = 0.3
        var negative = base
        negative.halation = -0.5
        negative.glow = -0.7
        negative.softness = -0.4
        XCTAssertEqual(try render(negative).pixels, try render(base).pixels)
    }

    func testHalationBleedsRedIntoARingAndLeavesTheFarGroundAlone() throws {
        var s = EnhanceSettings()
        s.halation = 0.5
        let before = Self.frame(), after = try render(s)
        let b = Self.rgb(before, ring.x, ring.y), a = Self.rgb(after, ring.x, ring.y)
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        XCTAssertGreaterThan(dr, 1000, "a visible red halo around the highlight (red rose \(dr))")
        XCTAssertGreaterThan(dr, dg, "red rises more than green")
        XCTAssertGreaterThan(dr, db * 4, "red rises far more than blue (blue rose \(db))")

        let fb = Self.rgb(before, far.x, far.y), fa = Self.rgb(after, far.x, far.y)
        XCTAssertLessThanOrEqual(abs(fa.r - fb.r), 2, "the far ground is unchanged")
        XCTAssertLessThanOrEqual(abs(fa.g - fb.g), 2)
        XCTAssertLessThanOrEqual(abs(fa.b - fb.b), 2)
    }

    func testGlowLiftsAllThreeChannelsNearTheSquare() throws {
        var s = EnhanceSettings()
        s.glow = 0.5
        let before = Self.frame(), after = try render(s)
        let ringGlow = (x: 548, y: 512)
        let b = Self.rgb(before, ringGlow.x, ringGlow.y), a = Self.rgb(after, ringGlow.x, ringGlow.y)
        XCTAssertGreaterThan(a.r - b.r, 1000)
        XCTAssertGreaterThan(a.g - b.g, 1000)
        XCTAssertGreaterThan(a.b - b.b, 1000)
        // Neutral: the three rise together, within a tenth of each other.
        let rises = [a.r - b.r, a.g - b.g, a.b - b.b].map(Double.init)
        XCTAssertLessThan((rises.max()! - rises.min()!) / rises.max()!, 0.1, "glow keeps the colour, \(rises)")

        let fb = Self.rgb(before, far.x, far.y), fa = Self.rgb(after, far.x, far.y)
        XCTAssertLessThanOrEqual(abs(fa.r - fb.r), 2, "dark ground below the knee does not glow")
    }

    /// A black and white Look never carries Halation, because the halo is tinted red and
    /// runs AFTER saturation, so it would put color back into a monochrome frame. Glow is
    /// neutral and may.
    @MainActor
    func testNoBlackAndWhiteLookCarriesHalation() throws {
        let looks = ShippedLooks.all
        XCTAssertFalse(looks.isEmpty)
        for look in looks where ShippedLooks.blackAndWhiteLookIDs.contains(look.id) {
            XCTAssertEqual(look.settings.halation, 0, look.name)
        }
    }

    func testTheControlsEndDetail() {
        XCTAssertEqual(EnhanceControl.group(.detail).suffix(3).map(\.id), ["glow", "halation", "softness"])
        XCTAssertTrue(EnhanceControl.coversSliderKeys)
    }

    // MARK: Softness

    /// A one-pixel checker, the most high-frequency picture there is.
    static func checker(side: Int = 512) -> DecodedFrame {
        var px = [UInt16](repeating: 0, count: side * side * 3)
        for y in 0..<side { for x in 0..<side where (x + y) % 2 == 0 {
            let i = (y * side + x) * 3; px[i] = 52000; px[i + 1] = 52000; px[i + 2] = 52000
        } }
        for y in 0..<side { for x in 0..<side where (x + y) % 2 == 1 {
            let i = (y * side + x) * 3; px[i] = 14000; px[i + 1] = 14000; px[i + 2] = 14000
        } }
        return DecodedFrame(width: side, height: side, pixels: px)
    }

    /// Mean absolute difference between horizontal neighbours, green channel, away from
    /// the border: the high-frequency energy of the frame.
    static func neighbourEnergy(_ f: DecodedFrame) -> Double {
        var sum = 0.0, n = 0
        for y in 16..<(f.height - 16) { for x in 16..<(f.width - 17) {
            let i = (y * f.width + x) * 3 + 1
            sum += abs(Double(f.pixels[i]) - Double(f.pixels[i + 3])); n += 1
        } }
        return sum / Double(n)
    }

    func testSoftnessLowersHighFrequencyEnergy() throws {
        let before = Self.neighbourEnergy(Self.checker())
        var s = EnhanceSettings()
        s.softness = 0.5
        let half = Self.neighbourEnergy(try CoreImageEnhance().apply(Self.checker(), settings: s))
        s.softness = 1
        let full = Self.neighbourEnergy(try CoreImageEnhance().apply(Self.checker(), settings: s))
        XCTAssertLessThan(half, before * 0.7, "0.5 lowers the checker's energy (\(before) to \(half))")
        XCTAssertLessThan(full, half, "1 lowers it further (\(full))")
    }

    func testSoftnessAtZeroIsByteIdentical() throws {
        var s = EnhanceSettings()
        s.softness = 0
        XCTAssertEqual(try CoreImageEnhance().apply(Self.checker(), settings: s).pixels, Self.checker().pixels)
    }

    /// `CIUnsharpMask` ignores a negative intensity, so a negative Definition softens
    /// nothing (measured: byte-identical to 0). The chain clamps it at 0, and Softness is
    /// the control that softens.
    func testANegativeDefinitionIsTheSameAsZero() throws {
        func render(_ d: Double) throws -> DecodedFrame {
            var s = EnhanceSettings(); s.definition = d; s.vignette = 0.2
            return try CoreImageEnhance().apply(Self.checker(), settings: s)
        }
        let zero = try render(0)
        XCTAssertEqual(try render(-0.5).pixels, zero.pixels)
        XCTAssertEqual(try render(-1).pixels, zero.pixels)
        XCTAssertNotEqual(try render(0.5).pixels, zero.pixels, "the positive half still acts")
    }
}

import XCTest
import CoreImage
import FilmSidecar
@testable import FilmPositiveCore
@testable import FilmPositive

/// The vignette's Size and Softness. Read off the mask itself, as weights in Core Image's
/// working space, which is what `CIBlendWithMask` blends by.
final class VignetteSizeSoftnessTests: XCTestCase {

    static let ext = CGRect(x: 0, y: 0, width: 600, height: 400)

    /// The mask exactly as drawn before Size and Softness, copied with its literal
    /// constants, so the identity claim is against the old code and not against itself.
    static func originalMask(_ ext: CGRect) -> CIImage {
        let hw = ext.width / 2, hh = ext.height / 2
        let ring = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": 0.25 * hw,
            "inputRadius1": 1.35 * hw,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])!.outputImage!
        let oval = ring
            .transformed(by: CGAffineTransform(scaleX: 1, y: hh / hw))
            .transformed(by: CGAffineTransform(translationX: ext.midX, y: ext.midY))
        return oval.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: oval])
            .cropped(to: ext)
    }

    /// The original vignette stage, with its own mask, for the stage-level identity.
    static func originalVignette(_ ci: CIImage, amount: Double, ext: CGRect) -> CIImage {
        let t = CGFloat(min(abs(amount), 1)) * 0.85
        let keep = 1 - t, lift = amount > 0 ? 0 : t
        let edge = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
            "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0),
        ])
        return edge.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: ci, kCIInputMaskImageKey: originalMask(ext),
        ]).cropped(to: ext)
    }

    /// RGBA float, in the working space (no color matching), row by row from the top.
    static func floats(_ ci: CIImage, _ rect: CGRect, colorSpace: CGColorSpace? = nil) -> [Float] {
        let w = Int(rect.width), h = Int(rect.height)
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            CoreImageEnhance.context.render(ci, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: rect,
                                            format: .RGBAf, colorSpace: colorSpace)
        }
        return out
    }

    /// The mask's weight per pixel (its red channel).
    static func weights(_ ci: CIImage, _ rect: CGRect) -> [Float] {
        let px = floats(ci, rect)
        return stride(from: 0, to: px.count, by: 4).map { px[$0] }
    }

    static func meanWeight(size: Double, softness: Double) -> Double {
        let px = floats(CoreImageEnhance.vignetteMask(ext, size: size, softness: softness), ext)
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Double(px[i]) }
        return sum / Double(px.count / 4)
    }

    /// The 10 to 90 percent band along the horizontal midline, in pixels, read off the
    /// uncropped field from the center out to 2.5 half widths, because at Size 0 the old
    /// band runs past the frame's edge (90 percent falls at 1.29 half widths).
    static func band(size: Double, softness: Double) -> Double {
        let hw = ext.width / 2
        let row = CGRect(x: ext.midX, y: ext.midY, width: (2.5 * hw).rounded(), height: 1)
        let px = floats(CoreImageEnhance.vignetteField(ext, size: size, softness: softness), row)
        let line = stride(from: 0, to: px.count, by: 4).map { Double(px[$0]) }
        guard let p10 = line.firstIndex(where: { $0 >= 0.1 }), let p90 = line.firstIndex(where: { $0 >= 0.9 }) else {
            XCTFail("the band at size \(size), softness \(softness) does not reach 90 percent within 2.5 half widths")
            return .nan
        }
        return Double(p90 - p10)
    }

    // MARK: identity

    /// At 0 and 0 the mask is byte-identical to the original, in the working space and through the
    /// output sRGB, on both orientations and an offset extent.
    func testAtZeroTheMaskIsByteIdenticalToTheOriginal() {
        let exts = [Self.ext, CGRect(x: 0, y: 0, width: 400, height: 600), CGRect(x: 13, y: 7, width: 301, height: 199)]
        for e in exts {
            let old = Self.originalMask(e)
            for new in [CoreImageEnhance.vignetteMask(e), CoreImageEnhance.vignetteMask(e, size: 0, softness: 0),
                        CoreImageEnhance.vignetteMask(e, size: -0.0, softness: -0.0)] {
                for space in [nil, CoreImageEnhance.srgb] {
                    let a = Self.floats(old, e, colorSpace: space), b = Self.floats(new, e, colorSpace: space)
                    XCTAssertTrue(a.map(\.bitPattern) == b.map(\.bitPattern), "\(e) \(String(describing: space))")
                }
            }
        }
        XCTAssertEqual(CoreImageEnhance.vignetteRadii(size: 0, softness: 0).inner, CoreImageEnhance.vignetteInner)
        XCTAssertEqual(CoreImageEnhance.vignetteRadii(size: 0, softness: 0).outer, CoreImageEnhance.vignetteOuter)
    }

    /// The whole stage too, amount math included, at both signs.
    func testAtZeroTheStageIsByteIdenticalToTheOriginal() {
        let f = VignetteShapeTests.grey(600, 400)
        let input = CoreImageEnhance.image(f)
        for amount in [0.6, -0.6, 1.0, -2.5] {
            let old = Self.originalVignette(input, amount: amount, ext: input.extent)
            let new = CoreImageEnhance.vignette(input, amount: amount, ext: input.extent, size: 0, softness: 0)
            XCTAssertTrue(Self.floats(old, input.extent).map(\.bitPattern) == Self.floats(new, input.extent).map(\.bitPattern),
                          "amount \(amount)")
        }
    }

    /// An older sidecar has neither key, and reads them as 0, so it renders as it did.
    func testAnOldVignetteRendersTheSameThroughTheChain() throws {
        var old = EnhanceSettings(); old.vignette = -0.6
        let decoded = try JSONDecoder().decode(EnhanceSettings.self, from: Data(#"{"vignette": -0.6}"#.utf8))
        XCTAssertEqual(decoded.vignetteSize, 0)
        XCTAssertEqual(decoded.vignetteFeather, 0)
        let f = VignetteShapeTests.grey(300, 200)
        XCTAssertEqual(try CoreImageEnhance().apply(f, settings: decoded).pixels,
                       try CoreImageEnhance().apply(f, settings: old).pixels)
    }

    // MARK: the two directions

    /// Right reaches further toward the center, so more of the frame carries weight.
    func testMeanWeightRisesWithSize() {
        let sizes = [-1.0, -0.5, 0, 0.5, 1]
        let means = sizes.map { Self.meanWeight(size: $0, softness: 0) }
        print("mean mask weight by size \(sizes): \(means)")
        for (a, b) in zip(means, means.dropFirst()) {
            XCTAssertGreaterThan(b, a + 0.01, "mean weight by size \(sizes): \(means)")
        }
    }

    /// Right widens the transition, left narrows it, and the narrowest is still a ramp tens
    /// of pixels wide rather than an aliased step.
    func testTheTransitionBandWidensWithSoftness() {
        let softness = [-1.0, -0.5, 0, 0.5, 1]
        let bands = softness.map { Self.band(size: 0, softness: $0) }
        print("10-90 band px by softness \(softness): \(bands)")
        for (a, b) in zip(bands, bands.dropFirst()) {
            XCTAssertGreaterThan(b, a + 5, "10 to 90 band in pixels by softness \(softness): \(bands)")
        }
        XCTAssertGreaterThan(bands[0], 0.15 * Self.ext.width, "hardest is still a ramp: \(bands[0]) px")
        XCTAssertEqual(Self.band(size: 0, softness: -3), bands[0], "a typed -3 clamps to -1")
        // And at another Size, so the two are not tied to one place.
        let shifted = [-1.0, 0, 1].map { Self.band(size: 0.5, softness: $0) }
        XCTAssertLessThan(shifted[0], shifted[1], "\(shifted)")
        XCTAssertLessThan(shifted[1], shifted[2], "\(shifted)")
    }

    /// Size moves the band: right pulls the 10 percent point in, left pushes it out.
    func testSizeMovesWhereTheVignetteStarts() {
        func onset(_ size: Double) -> Int {
            let hw = Self.ext.width / 2
            let row = CGRect(x: Self.ext.midX, y: Self.ext.midY, width: (2.5 * hw).rounded(), height: 1)
            let px = Self.floats(CoreImageEnhance.vignetteField(Self.ext, size: size, softness: 0), row)
            return stride(from: 0, to: px.count, by: 4).map { px[$0] }.firstIndex { $0 >= 0.1 } ?? .max
        }
        XCTAssertLessThan(onset(1), onset(0))
        XCTAssertLessThan(onset(0), onset(-1))
    }

    // MARK: legal everywhere

    /// Every radius is legal for `CIRadialGradient` across the range, typed values and
    /// non-numbers included: inner at least 0, outer clear of it, both finite.
    func testRadiiAreLegalAcrossTheWholeRange() {
        let values = stride(from: -3.0, through: 3.0, by: 0.25).map { $0 } + [.nan, .infinity, -.infinity, 1e9]
        for s in values { for f in values {
            let r = CoreImageEnhance.vignetteRadii(size: s, softness: f)
            XCTAssertTrue(r.inner.isFinite && r.outer.isFinite, "size \(s) softness \(f): \(r)")
            XCTAssertGreaterThanOrEqual(r.inner, 0, "size \(s) softness \(f)")
            XCTAssertGreaterThan(r.outer - r.inner, 0.6, "size \(s) softness \(f): \(r)")
        } }
        XCTAssertTrue(CoreImageEnhance.vignetteRadii(size: -3, softness: 3) == CoreImageEnhance.vignetteRadii(size: -1, softness: 1))
        XCTAssertTrue(CoreImageEnhance.vignetteRadii(size: 3, softness: -3) == CoreImageEnhance.vignetteRadii(size: 1, softness: -1))
    }

    /// The masks at the corners of the typed range render, every weight a number in 0...1.
    func testTheMaskRendersAtPlusAndMinusThree() {
        for s in [-3.0, 3] { for f in [-3.0, 3] {
            let w = Self.weights(CoreImageEnhance.vignetteMask(Self.ext, size: s, softness: f), Self.ext)
            XCTAssertTrue(w.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "size \(s) softness \(f)")
            XCTAssertGreaterThan(w.max() ?? 0, 0.2, "something is vignetted at size \(s) softness \(f)")
        } }
    }

    /// With Amount at 0 the other two do nothing, and the stage does not run.
    func testWithAmountAtZeroSizeAndSoftnessDoNothing() throws {
        let f = VignetteShapeTests.grey(300, 200)
        var plain = EnhanceSettings(); plain.exposure = 0.1
        var shaped = plain; shaped.vignetteSize = 1; shaped.vignetteFeather = -1
        XCTAssertEqual(try CoreImageEnhance().apply(f, settings: shaped).pixels,
                       try CoreImageEnhance().apply(f, settings: plain).pixels)
        shaped.vignetteSize = -3; shaped.vignetteFeather = 3
        XCTAssertEqual(try CoreImageEnhance().apply(f, settings: shaped).pixels,
                       try CoreImageEnhance().apply(f, settings: plain).pixels)
    }

    /// Through the chain on a grey frame: Size right darkens an edge's midpoint that Size
    /// left leaves nearly alone, and the center stays put at Size 0.
    func testThroughTheChainSizeReachesInward() throws {
        let f = VignetteShapeTests.grey(600, 400)
        func green(_ size: Double, _ x: Int, _ y: Int) throws -> Int {
            var s = EnhanceSettings(); s.vignette = -1; s.vignetteSize = size
            let o = try CoreImageEnhance().apply(f, settings: s)
            return Int(o.pixels[(y * o.width + x) * 3 + 1])
        }
        let left = (x: 1, y: 200)
        XCTAssertLessThan(try green(1, left.x, left.y), try green(0, left.x, left.y) - 3000, "right darkens the edge more")
        XCTAssertGreaterThan(try green(-1, left.x, left.y), try green(0, left.x, left.y) + 3000, "left keeps to the corners")
        XCTAssertEqual(try green(0, 300, 200), 32767, accuracy: 300, "the centre stays put")
    }
}

import XCTest
import CoreImage
import FilmSidecar
@testable import FilmPositiveCore

/// Levels and Curves in the enhance chain. Rendered on grey ramps, so every assertion
/// is a reading of known display-encoded values.
final class ToneStageRenderTests: XCTestCase {
    /// A horizontal grey ramp, one column per value, display encoded.
    static func ramp(_ values: [Double], rows: Int = 2) -> DecodedFrame {
        var px: [UInt16] = []
        for _ in 0..<rows {
            for v in values { let u = UInt16((min(max(v, 0), 1) * 65535).rounded()); px += [u, u, u] }
        }
        return DecodedFrame(width: values.count, height: rows, pixels: px)
    }

    static let fullRamp = ramp((0..<256).map { Double($0) / 255 })

    static func channel(_ f: DecodedFrame, _ c: Int) -> [Double] {
        (0..<f.width).map { Double(f.pixels[$0 * 3 + c]) / 65535 }
    }

    static func mean(_ f: DecodedFrame, _ c: Int) -> Double {
        let v = channel(f, c)
        return v.reduce(0, +) / Double(v.count)
    }

    /// Renders `chain` the way `apply` does, so a stopped chain can be compared byte for byte.
    static func renderChain(_ s: EnhanceSettings, _ f: DecodedFrame, stoppingBefore stop: EnhanceToneStage?) -> [UInt16] {
        let (ci, ext) = CoreImageEnhance.chain(s, CoreImageEnhance.image(f), stoppingBefore: stop)
        var rgba = [UInt16](repeating: 0, count: f.width * f.height * 4)
        rgba.withUnsafeMutableBytes { buf in
            CoreImageEnhance.context.render(ci, toBitmap: buf.baseAddress!, rowBytes: f.width * 8, bounds: ext,
                                            format: .RGBA16, colorSpace: CoreImageEnhance.srgb)
        }
        return stride(from: 0, to: rgba.count, by: 4).flatMap { [rgba[$0], rgba[$0 + 1], rgba[$0 + 2]] }
    }

    static func curve(_ p: [(Double, Double)]) -> CurvePoints {
        CurvePoints(sanitising: p.map { CurvePoint(x: $0.0, y: $0.1) })
    }

    // MARK: identity

    /// Neither stage set: the render is byte-identical to the same sliders with no Levels or
    /// Curves at all, including when the identity was reached by building it rather than by
    /// default (a curve sanitised from reversed end points is the identity).
    func testIdentityLevelsAndCurvesRenderByteIdentical() throws {
        var s = EnhanceSettings()
        s.exposure = 0.2; s.contrast = 0.3; s.brightness = -0.2; s.warmth = 0.2; s.saturation = 0.3
        let plain = try CoreImageEnhance().apply(Self.fullRamp, settings: s)
        var built = s
        built.levels = Levels(inBlack: 0, gamma: 1, inWhite: 1, outBlack: 0, outWhite: 1)
        built.curves = Curves(rgb: Self.curve([(1, 1), (0, 0)]), red: .identity, green: .identity, blue: .identity)
        XCTAssertTrue(built.levels.isIdentity && built.curves.isIdentity)
        let again = try CoreImageEnhance().apply(Self.fullRamp, settings: built)
        XCTAssertEqual(plain.pixels, again.pixels, "identity Levels and Curves change no byte")
        // And the frame itself when nothing at all is set.
        let none = try CoreImageEnhance().apply(Self.fullRamp, settings: EnhanceSettings())
        XCTAssertEqual(none.pixels, Self.fullRamp.pixels)
    }

    /// The guard is not hiding a dead stage: the smallest non-identity Levels and Curves each
    /// change the picture.
    func testTheSmallestMoveOfEitherStageRenders() throws {
        var l = EnhanceSettings(); l.levels.gamma = 1.05
        var c = EnhanceSettings(); c.curves.rgb = Self.curve([(0, 0), (0.5, 0.52), (1, 1)])
        let a = try CoreImageEnhance().apply(Self.fullRamp, settings: l)
        let b = try CoreImageEnhance().apply(Self.fullRamp, settings: c)
        XCTAssertNotEqual(a.pixels, Self.fullRamp.pixels)
        XCTAssertNotEqual(b.pixels, Self.fullRamp.pixels)
    }

    // MARK: Levels

    func testLevelsFormulaAtKnownValues() {
        let l = Levels(inBlack: 0.1, gamma: 2, inWhite: 0.9, outBlack: 0.05, outWhite: 0.95)
        // (0.5 - 0.1) / 0.8 = 0.5, 0.5^(1/2) = 0.70711, 0.05 + 0.9 * 0.70711 = 0.68640
        XCTAssertEqual(LevelsMath.apply(l, to: 0.5), 0.68640, accuracy: 0.00001)
        XCTAssertEqual(LevelsMath.apply(l, to: 0.05), 0.05, accuracy: 1e-12, "below input black is output black")
        XCTAssertEqual(LevelsMath.apply(l, to: 0.95), 0.95, accuracy: 1e-12, "above input white is output white")
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(LevelsMath.apply(.identity, to: v), v, accuracy: 1e-12)
        }
    }

    func testLevelsGuardHoldsGammaAndTheInputSpan() {
        XCTAssertEqual(LevelsMath.guarded(Levels(gamma: 40)).gamma, 10)
        XCTAssertEqual(LevelsMath.guarded(Levels(gamma: 0.001)).gamma, 0.1)
        XCTAssertEqual(LevelsMath.guarded(Levels(gamma: -3)).gamma, 0.1)
        let crossed = LevelsMath.guarded(Levels(inBlack: 0.6, inWhite: 0.3))
        XCTAssertEqual(crossed.inBlack, 0.6)
        XCTAssertEqual(crossed.inWhite, 0.61, accuracy: 1e-12, "white is kept 0.01 above black")
        XCTAssertEqual(LevelsMath.guarded(Levels(gamma: .nan)).gamma, 1, "a non-finite field is that field's identity")
        // A crossed or degenerate set still renders finite numbers.
        XCTAssertTrue(LevelsMath.apply(Levels(inBlack: 0.5, inWhite: 0.5), to: 0.7).isFinite)
    }

    func testTheRenderFollowsTheFormulaInDisplayEncoding() throws {
        let values = [0.05, 0.1, 0.25, 0.5, 0.6, 0.75, 0.9, 0.95]
        let l = Levels(inBlack: 0.1, gamma: 2, inWhite: 0.9, outBlack: 0.05, outWhite: 0.95)
        var s = EnhanceSettings(); s.levels = l
        let out = try CoreImageEnhance().apply(Self.ramp(values), settings: s)
        let got = Self.channel(out, 1)
        for (i, v) in values.enumerated() {
            XCTAssertEqual(got[i], LevelsMath.apply(l, to: (v * 65535).rounded() / 65535), accuracy: 0.001,
                           "encoded \(v)")
        }
    }

    func testMidtoneAboveOneBrightens() throws {
        var s = EnhanceSettings(); s.levels.gamma = 1.6
        let out = try CoreImageEnhance().apply(Self.fullRamp, settings: s)
        XCTAssertGreaterThan(Self.mean(out, 1), Self.mean(Self.fullRamp, 1) + 0.05)
    }

    // MARK: Curves

    func testTheCurvePassesThroughItsPoints() {
        let points = [(0.0, 0.0), (0.2, 0.35), (0.5, 0.5), (0.8, 0.9), (1.0, 1.0)]
        let c = MonotoneCurve(Self.curve(points))
        for (x, y) in points { XCTAssertEqual(c.value(at: x), y, accuracy: 1e-9, "through (\(x), \(y))") }
    }

    /// A sharp bend between rising points: a natural spline overshoots next to it, this one
    /// keeps rising and stays inside each pair's band.
    func testMonotoneBetweenMonotonePointsWithNoOvershoot() {
        let points = [(0.0, 0.0), (0.1, 0.6), (0.2, 0.65), (0.6, 0.66), (1.0, 1.0)]
        let c = MonotoneCurve(Self.curve(points))
        var last = -1.0
        for i in 0...2000 {
            let x = Double(i) / 2000, y = c.value(at: x)
            XCTAssertGreaterThanOrEqual(y, last - 1e-12, "rising at \(x)")
            last = y
            if let k = points.indices.last(where: { points[$0].0 <= x }), k < points.count - 1 {
                XCTAssertGreaterThanOrEqual(y, points[k].1 - 1e-12)
                XCTAssertLessThanOrEqual(y, points[k + 1].1 + 1e-12, "no overshoot past (\(points[k + 1]))")
            }
        }
    }

    func testAWildCurveNeverLeavesZeroToOne() {
        let c = MonotoneCurve(Self.curve([(0, 0), (0.05, 1), (0.1, 0), (0.15, 1), (0.5, 0.02), (1, 0)]))
        for i in 0...4000 {
            let y = c.value(at: Double(i) / 4000)
            XCTAssertTrue((0...1).contains(y), "inside 0...1 at \(Double(i) / 4000): \(y)")
        }
        // A peak at a point stays at that point: the tangent there is flat.
        XCTAssertEqual(c.value(at: 0.05), 1, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(c.value(at: 0.06), 1)
    }

    func testOutsideTheEndPointsTheCurveHoldsTheirValues() {
        let c = MonotoneCurve(Self.curve([(0.2, 0.1), (0.8, 0.9)]))
        XCTAssertEqual(c.value(at: 0), 0.1)
        XCTAssertEqual(c.value(at: 0.1), 0.1)
        XCTAssertEqual(c.value(at: 1), 0.9)
    }

    func testTheTableIsRGBThenEachChannel() {
        let curves = Curves(rgb: Self.curve([(0, 0), (0.5, 0.7), (1, 1)]),
                            red: Self.curve([(0, 0.2), (1, 1)]), green: .identity, blue: Self.curve([(0, 0), (1, 0.5)]))
        let t = CurveTable.table(curves)
        XCTAssertEqual(t.count, CurveTable.size * 3)
        let mid = (CurveTable.size - 1) / 2, x = Double(mid) / Double(CurveTable.size - 1)
        let all = MonotoneCurve(curves.rgb).value(at: x)
        XCTAssertEqual(Double(t[mid * 3]), MonotoneCurve(curves.red).value(at: all), accuracy: 1e-6)
        XCTAssertEqual(Double(t[mid * 3 + 1]), all, accuracy: 1e-6)
        XCTAssertEqual(Double(t[mid * 3 + 2]), MonotoneCurve(curves.blue).value(at: all), accuracy: 1e-6)
    }

    func testTheRenderFollowsTheCurveInDisplayEncoding() throws {
        var s = EnhanceSettings(); s.curves.rgb = Self.curve([(0, 0), (0.5, 0.7), (1, 1)])
        let values = [0.1, 0.25, 0.5, 0.75, 0.9]
        let out = try CoreImageEnhance().apply(Self.ramp(values), settings: s)
        let c = MonotoneCurve(s.curves.rgb)
        for (i, v) in Self.channel(out, 0).enumerated() {
            XCTAssertEqual(v, c.value(at: values[i]), accuracy: 0.002, "encoded \(values[i])")
        }
    }

    /// A red-only curve moves red and leaves green and blue where they were.
    func testAChannelCurveMovesOnlyItsChannel() throws {
        for (channel, path) in [(0, \Curves.red), (1, \Curves.green), (2, \Curves.blue)] {
            var s = EnhanceSettings()
            s.curves[keyPath: path] = Self.curve([(0, 0), (0.5, 0.75), (1, 1)])
            let out = try CoreImageEnhance().apply(Self.fullRamp, settings: s)
            for c in 0..<3 {
                let moved = Self.mean(out, c) - Self.mean(Self.fullRamp, c)
                if c == channel {
                    XCTAssertGreaterThan(moved, 0.1, "channel \(c) moves under its own curve")
                } else {
                    let worst = zip(Self.channel(out, c), Self.channel(Self.fullRamp, c)).map { abs($0 - $1) }.max() ?? 1
                    XCTAssertLessThan(worst, 0.0005, "channel \(c) holds still under channel \(channel)'s curve")
                }
            }
        }
    }

    // MARK: the picture entering each step

    /// The settings the inspector renders for a step's histogram give the same bytes as the
    /// chain itself stopped just before that step. This is what keeps `entering` honest if
    /// the chain is ever reordered.
    func testEnteringSettingsMatchTheStoppedChain() {
        var s = EnhanceSettings()
        s.exposure = 0.15; s.radiance = 0.3; s.shadows = 0.2; s.highlights = -0.2; s.blackPoint = 0.1
        s.contrast = 0.25; s.brightness = 0.1
        s.levels = Levels(inBlack: 0.05, gamma: 1.3, inWhite: 0.95)
        s.curves.rgb = Self.curve([(0, 0), (0.4, 0.5), (1, 1)])
        s.warmth = 0.3; s.saturation = 0.4; s.vignette = 0.3; s.definition = 0.2
        let f = Self.ramp((0..<64).map { Double($0) / 63 }, rows: 48)
        for step in [EnhanceToneStage.levels, .curves] {
            let stopped = Self.renderChain(s, f, stoppingBefore: step)
            let pruned = Self.renderChain(CoreImageEnhance.entering(step, s), f, stoppingBefore: nil)
            XCTAssertEqual(stopped, pruned, "the picture entering \(step)")
        }
        XCTAssertTrue(CoreImageEnhance.entering(.levels, s).levels.isIdentity)
        XCTAssertEqual(CoreImageEnhance.entering(.curves, s).levels, s.levels)
        XCTAssertTrue(CoreImageEnhance.entering(.curves, s).curves.isIdentity)
    }
}

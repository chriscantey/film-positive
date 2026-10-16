import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Core Image's shadow and highlight adjust has dead zones. Shadows up to ±0.06 and Highlights
/// -0.07 to 0 render bit for bit as 0, and Shadows -0.14 to -0.20 darken less than -0.13. The
/// chain crossfades through them. Each slider's first step acts, and its mean moves one way
/// across the whole range at 0.05 steps.
final class ToneDeadZoneTests: XCTestCase {
    static let frame = AutoEnhanceTests.ramp(lo: 0.02, hi: 0.98, w: 400, h: 250)

    static func mean(_ s: EnhanceSettings) throws -> Double {
        let px = try CoreImageEnhance().apply(frame, settings: s).pixels
        return px.reduce(0.0) { $0 + Double($1) } / Double(px.count) / 65535
    }

    static func with(_ path: WritableKeyPath<EnhanceSettings, Double>, _ v: Double) -> EnhanceSettings {
        var s = EnhanceSettings.identity; s[keyPath: path] = v; return s
    }

    func testZeroIsStillIdentity() throws {
        let id = try CoreImageEnhance().apply(Self.frame, settings: .identity).pixels
        XCTAssertEqual(try CoreImageEnhance().apply(Self.frame, settings: Self.with(\.shadows, 0)).pixels, id)
        XCTAssertEqual(try CoreImageEnhance().apply(Self.frame, settings: Self.with(\.highlights, 0)).pixels, id)
    }

    func testTheFirstStepActs() throws {
        let zero = try Self.mean(.identity)
        XCTAssertGreaterThan(try Self.mean(Self.with(\.shadows, 0.02)), zero, "Shadows +0.02")
        XCTAssertLessThan(try Self.mean(Self.with(\.shadows, -0.02)), zero, "Shadows -0.02")
        XCTAssertLessThan(try Self.mean(Self.with(\.highlights, -0.02)), zero, "Highlights -0.02")
        XCTAssertGreaterThan(try Self.mean(Self.with(\.highlights, 0.02)), zero, "Highlights +0.02")
    }

    func testEachSliderIsMonotoneAcrossItsRange() throws {
        for (name, path) in [("Shadows", \EnhanceSettings.shadows), ("Highlights", \EnhanceSettings.highlights)] {
            var last = -Double.infinity
            for i in -20...20 {
                let v = Double(i) * 0.05
                let m = try Self.mean(Self.with(path, v))
                XCTAssertGreaterThan(m, last, "\(name) \(v) is not brighter than \(v - 0.05)")
                last = m
            }
        }
    }
}

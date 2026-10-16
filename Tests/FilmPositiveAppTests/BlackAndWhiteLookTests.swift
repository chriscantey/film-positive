import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The black and white path needs no profile, Auto tone applies to it, and at least two
/// shipped looks are tuned for it, one of them derived from a set of black and white exports
/// rather than from taste.
///
/// The derivation is the part worth testing. Ink's sliders (id `overcast`) were fitted
/// against the tone curve in `Fixtures/bw-park-classic.json`, taken from
/// hand edits of a black and white roll. This test re-runs that comparison against the
/// numbers actually shipped, so the look cannot drift away from the curve it claims to come
/// from without a failure.
final class BlackAndWhiteLookTests: XCTestCase {

    private func curve() throws -> [Double] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bw-park-classic.json")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any] ?? [:]
        let curves = object["curves"] as? [String: [Double]] ?? [:]
        return try XCTUnwrap(curves["g"])
    }

    /// A grey ramp wide enough to read the curve and tall enough for the chain's local
    /// operators to have a neighbourhood.
    private func greyRamp(steps: Int = 256, rows: Int = 8) -> DecodedFrame {
        var pixels = [UInt16](repeating: 0, count: steps * rows * 3)
        for y in 0..<rows {
            for x in 0..<steps {
                let v = UInt16(Double(x) / Double(steps - 1) * 65535)
                let i = (y * steps + x) * 3
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        return DecodedFrame(width: steps, height: rows, pixels: pixels)
    }

    func testThreeBlackAndWhiteLooksShip() {
        // Chalk (id `silver`) the hard print, Ink (id `overcast`) the dark soft one, Cloud (id
        // `bright-print`) the bright one.
        XCTAssertEqual(ShippedLooks.blackAndWhiteLookIDs, ["silver", "overcast", "bright-print"])
        for id in ShippedLooks.blackAndWhiteLookIDs {
            let look = ShippedLooks.look(id)
            XCTAssertNotNil(look, "\(id) is named as a black and white look and is not shipped")
            XCTAssertEqual(look?.settings.saturation, -1.0, "\(id) has to be monochrome")
            XCTAssertTrue(look?.shipped ?? false)
        }
    }

    /// The fitted curve with its toe and shoulder relaxed part of the way toward the
    /// straight lines through its own black, mid grey and white. Those three points do not
    /// move, so the blacks stay on the floor and the middle stays where it was, and the S
    /// between them is shallower. Halfway, the default, is the curve the shipped Look tracks.
    static func softened(_ g: [Double], by a: Double = 0.5) -> [Double] {
        let gm = g[128]
        return (0..<256).map { i in
            let line = i <= 128 ? gm * Double(i) / 128 : gm + (1 - gm) * Double(i - 128) / 127
            return g[i] + a * (line - g[i])
        }
    }

    /// The shipped sliders reproduce the softened curve, stay close to the curve they were
    /// first fitted to (the lineage), are a real improvement over doing nothing (the control
    /// that makes the number mean something), and really are a step softer on the ramp.
    func testInkReproducesItsCurve() throws {
        let original = try curve()
        let target = Self.softened(original)
        let ramp = greyRamp()
        let stage = CoreImageEnhance()
        let ink = try XCTUnwrap(ShippedLooks.look("overcast"))
        let row = (ramp.height / 2) * ramp.width * 3

        func rendered(_ settings: EnhanceSettings) throws -> [Double] {
            let out = try stage.apply(ramp, settings: settings)
            return (0..<ramp.width).map { Double(out.pixels[row + $0 * 3 + 1]) / 65535 }
        }
        func rmse(_ got: [Double], _ want: [Double]) -> Double {
            (zip(got, want).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(got.count)).squareRoot()
        }

        let got = try rendered(ink.settings)
        let identity = try rendered(EnhanceSettings(saturation: -1))
        let fitted = rmse(got, target)
        print("[looks] Ink rmse \(String(format: "%.5f", fitted)) against its softened curve, "
              + "\(String(format: "%.5f", rmse(got, original))) against the original fit, "
              + "identity \(String(format: "%.5f", rmse(identity, target))), "
              + "mid \(String(format: "%.3f", got[128])) spread \(String(format: "%.3f", got[192] - got[64]))")
        // Fitted to the original curve: 0.01753 with Radiance out of the
        // knobs (0.02194 with it), at a spread of 0.725. One step softer by hand gives spread
        // 0.682 and 0.0352 against this halfway curve, and the shipped Look is a second step,
        // see `Looks.swift`. The 0.028 and 0.65 bounds both fail on the first step's numbers.
        // The halfway curve sits nearer identity than the quarter one, so the control is half
        // of identity's error, not a third.
        XCTAssertLessThan(fitted, 0.028, "Ink no longer reproduces its curve")
        XCTAssertLessThan(fitted, rmse(identity, target) / 2, "the fit has to be a real improvement over doing nothing")
        XCTAssertLessThan(rmse(got, original), 0.04, "and it is still the same family as the curve it came from")
        XCTAssertEqual(got[128], original[128], accuracy: 0.01, "the middle stays where it was")
        XCTAssertLessThan(got[0], 0.01, "the blacks stay on the floor")
        XCTAssertLessThan(got[32], 0.01, "and an eighth of the way up is still ink black")
        XCTAssertLessThan(got[192] - got[64], 0.65, "two steps softer than the 0.725 the earlier numbers rendered")
    }

    /// The three black and white Looks are three different prints, not three settings of one.
    /// Read off the grey ramp at a quarter, a half and three quarters: Cloud is the brightest
    /// in the middle by a clear margin, Ink the darkest, and Chalk has the steepest middle,
    /// which is what "contrast forward" means on a curve.
    func testTheThreeBlackAndWhiteLooksAreThreeDifferentPrints() throws {
        let ramp = greyRamp()
        let stage = CoreImageEnhance()
        func curve(_ id: String) throws -> (q1: Double, mid: Double, q3: Double) {
            let look = try XCTUnwrap(ShippedLooks.look(id))
            let out = try stage.apply(ramp, settings: look.settings)
            let row = (ramp.height / 2) * ramp.width * 3
            func at(_ x: Int) -> Double { Double(out.pixels[row + x * 3 + 1]) / 65535 }
            return (at(64), at(128), at(192))
        }
        let chalk = try curve("silver"), ink = try curve("overcast"), cloud = try curve("bright-print")
        print("[looks] mid grey: chalk \(chalk) ink \(ink) cloud \(cloud)")
        XCTAssertGreaterThan(cloud.mid, max(chalk.mid, ink.mid) + 0.08, "Cloud is the bright one")
        XCTAssertLessThan(ink.mid, chalk.mid, "Ink is the dark one")
        XCTAssertLessThan(ink.q1, chalk.q1 - 0.05, "and softened twice, its shadows still sit well below Chalk's")
        XCTAssertGreaterThan(chalk.q3 - chalk.q1, cloud.q3 - cloud.q1, "Chalk is steeper through the middle than Cloud")
    }

    /// The black and white stock needs no profile and Auto tone applies to it.
    @MainActor
    func testTheBlackAndWhiteStockNeedsNoProfileAndTakesAutoTone() throws {
        let library = try ProfileLibrary.bundled()
        let mono = library.mono
        XCTAssertTrue(mono.isMono)
        XCTAssertNil(mono.datasheetDyeGamma, "the black and white path needs no dye gammas")

        let develop = DevelopSettings(stock: ProfileLibrary.monoStockID,
                                      autoTone: true, base: BaseSettings(mode: .anchor))
        XCTAssertTrue(develop.autoTone)
        let choices = StockChoices.list(from: library, current: nil)
        let monoChoice = try XCTUnwrap(choices.first { $0.kind == .mono })
        XCTAssertEqual(monoChoice.id, ProfileLibrary.monoStockID)
    }
}

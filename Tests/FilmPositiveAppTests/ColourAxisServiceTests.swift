import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// THE APP'S RENDERER, not the reference. `CPURenderService` renders through
/// `DevelopTables`, while the other axis tests (`ColourAxisWiringTests`,
/// `ColourAxisAuthorityTests`) exercise `DevelopMath.render`. Tables that miss the axis
/// offsets leave the Warm and Green sliders writing the sidecar and changing nothing on
/// screen, with every reference test still passing.
///
/// So these go through `CPURenderService.render`, the same call the app makes, with the axes
/// set on the `DevelopSettings` the sidecar carries.
final class ColourAxisServiceTests: XCTestCase {

    private func frame() -> DecodedFrame {
        SceneFixtures.neutralScene(castRG: 1.15, castBG: 0.92)
    }

    private func service() throws -> CPURenderService {
        let f = frame()
        return CPURenderService(profiles: try ProfileLibrary.bundled(), enhance: IdentityEnhance(),
                                decode: { _, _ in f })
    }

    private static let url = URL(fileURLWithPath: "/dev/null/synthetic.CR2")

    private func render(_ svc: CPURenderService, _ axes: ColourAxes) async throws -> DecodedFrame {
        var develop = DevelopSettings(stock: ProfileLibrary.genericStockID, autoTone: false,
                                      base: BaseSettings(mode: .anchor))
        develop.colourAxes = axes
        let result = try await svc.render(RenderRequest(imageURL: Self.url, develop: develop,
                                                        enhance: .identity, scale: .full))
        return result.frame
    }

    private func sums(_ f: DecodedFrame) -> [Double] {
        var s = [0.0, 0.0, 0.0]
        for i in stride(from: 0, to: f.pixels.count, by: 3) {
            for c in 0..<3 { s[c] += Double(f.pixels[i + c]) }
        }
        return s
    }

    /// Warm 5 must be a different picture from Warm 0 through the app's path.
    func testWarmChangesTheAppsRender() async throws {
        let svc = try service()
        let zero = try await render(svc, .identity)
        let warm = try await render(svc, ColourAxes(warm: 5))
        XCTAssertNotEqual(zero.pixels, warm.pixels, "Warm 5 rendered identical to Warm 0 in the app")
    }

    func testGreenChangesTheAppsRender() async throws {
        let svc = try service()
        let zero = try await render(svc, .identity)
        let green = try await render(svc, ColourAxes(green: 5))
        XCTAssertNotEqual(zero.pixels, green.pixels, "Green 5 rendered identical to Green 0 in the app")
    }

    /// And in the right direction, with the green channel untouched: the axes are offsets on
    /// red and blue only, so the app's green must come out byte for byte the same.
    func testTheAppsRenderMovesInTheAxesDirectionsAndHoldsGreen() async throws {
        let svc = try service()
        let zero = sums(try await render(svc, .identity))
        let warm = sums(try await render(svc, ColourAxes(warm: 5)))
        let magenta = sums(try await render(svc, ColourAxes(green: 5)))
        XCTAssertGreaterThan(warm[0], zero[0], "warm did not raise red")
        XCTAssertLessThan(warm[2], zero[2], "warm did not lower blue")
        XCTAssertGreaterThan(magenta[0], zero[0], "magenta did not raise red")
        XCTAssertGreaterThan(magenta[2], zero[2], "magenta did not raise blue")
        XCTAssertEqual(warm[1], zero[1], "warm moved green")
        XCTAssertEqual(magenta[1], zero[1], "magenta moved green")
    }

    /// The tables with the axes moved are bit-identical to the reference evaluator with the
    /// same axes, which is the contract `DevelopTables` has always claimed at zero.
    func testTablesMatchTheReferenceWithTheAxesMoved() {
        let f = frame()
        for axes in [ColourAxes(warm: 5), ColourAxes(green: -7), ColourAxes(warm: -3.5, green: 9)] {
            let input = DevelopInput(ratios: BaseRatios(rg: 1.08, bg: 0.94), dyeGamma: .neutral,
                                     mono: false, autoTone: false, colourAxes: axes)
            let (an, dens) = DevelopMath.analyze(f, input: input)
            let reference = DevelopMath.render(dens, analysis: an, flip: false)
            let fast = DevelopTables(analysis: an, mono: false, axisOffsets: input.axisOffsets)
                .apply(f, flip: false)
            XCTAssertEqual(fast.pixels, reference.pixels, "\(axes): tables and reference disagree")
        }
    }
}

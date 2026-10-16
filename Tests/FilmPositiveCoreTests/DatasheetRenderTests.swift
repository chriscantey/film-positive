import XCTest
import FilmSidecar
@testable import FilmPositiveCore

/// Where a datasheet stock's numbers come from at render time.
///
/// Stocks that carry `datasheetDyeGamma` off their own published characteristic curve
/// render DIFFERENTLY from the generic choice, and the ones with no published curve render
/// identically to it.
///
/// Both halves are asserted, because either one alone can pass while the other is broken:
/// a bug that drops every stock's own gammas passes the identity half, and a bug that
/// invents gammas for a stock that has none passes the difference half.
///
/// A stock whose sheet publishes a mask curve and no characteristic curve can be added at
/// any time, so the borrowing half is exercised against a library built from a copy of the
/// shipped one with one stock's gammas removed. The stock is then known to have no gammas
/// rather than merely observed not to have any.
final class DatasheetRenderTests: XCTestCase {

    private func service() throws -> CPURenderService {
        CPURenderService(profiles: try ProfileLibrary.bundled(), enhance: IdentityEnhance())
    }

    private func develop(_ stock: String) -> DevelopSettings {
        DevelopSettings(stock: stock, autoTone: true,
                        base: BaseSettings(mode: .anchor))
    }

    func testAStockWithNoPublishedCurveRendersExactlyLikeTheGenericChoice() throws {
        // The subject is made: a copy of the shipped profiles with Portra 400's published
        // dye gammas taken out.
        let bundled = try ProfileLibrary.bundled()
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-borrowing-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: bundled.root, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let film = temporary.appendingPathComponent("films/kodak-portra-400.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: film))
                                 as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "datasheetDyeGamma"),
                        "the stock this test strips has to have gammas to strip")
        try JSONSerialization.data(withJSONObject: json).write(to: film)

        let library = try ProfileLibrary(root: temporary)
        let borrower = try XCTUnwrap(library.films["kodak-portra-400"])
        XCTAssertFalse(borrower.isDatasheet, "a stock with no curve is not a datasheet stock")

        let svc = CPURenderService(profiles: library, enhance: IdentityEnhance())
        let generic = svc.developInput(for: develop("generic"))
        let input = svc.developInput(for: develop(borrower.id))
        XCTAssertEqual(input.ratios, generic.ratios, "base ratios differ from the generic choice")
        XCTAssertEqual(input.dyeGamma, generic.dyeGamma, "it borrows the generic stock's gammas, so they must match")
        XCTAssertEqual(input.dyeGamma, .neutral, "the generic stock carries no film opinion since 2026-09-23")
        XCTAssertEqual(input.mono, generic.mono)
        XCTAssertEqual(input.autoTone, generic.autoTone)

        // And with the gammas in place, the same stock out of the same library does not
        // match the generic choice. Without this the test above would pass on a library
        // that had lost every stock's gammas.
        let shipped = CPURenderService(profiles: bundled, enhance: IdentityEnhance())
        XCTAssertNotEqual(shipped.developInput(for: develop("kodak-portra-400")).dyeGamma,
                          shipped.developInput(for: develop("generic")).dyeGamma)

        // Nothing shipped is borrowing except the one stock offered without a curve.
        let borrowing = bundled.films.values.filter { !$0.isDatasheet && !$0.isMono && !$0.isHidden }
        XCTAssertEqual(borrowing.map(\.id), ["harman-switch-azure"],
                       "these ship without their own published gammas: "
                       + borrowing.map(\.id).sorted().joined(separator: ", "))
    }

    /// The control. A stock that carries its own published dye gammas has to render as
    /// itself, or the test above would pass by making everything identical.
    func testAStockWithItsOwnPublishedCurveRendersAsItself() throws {
        let svc = try service()
        let generic = svc.developInput(for: develop("generic"))
        let library = try ProfileLibrary.bundled()
        var checked = 0
        for film in library.films.values where film.isDatasheet {
            // The generic stock is one of these and is trivially equal to itself.
            guard film.id != ProfileLibrary.genericStockID else { continue }
            let input = svc.developInput(for: develop(film.id))
            XCTAssertNotEqual(input.dyeGamma, generic.dyeGamma,
                              "\(film.id) has published dye gammas and has to render with them")
            XCTAssertNotEqual(input.dyeGamma, .neutral,
                              "\(film.id) rendered with no per-channel normalisation at all")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 10, "the published-curve set shrank below the ten shipped colour stocks that are not the generic one")
    }

    /// And black and white is neither: neutral gammas and 1:1:1 ratios by physics.
    func testBlackAndWhiteIsNeutral() throws {
        let svc = try service()
        let mono = svc.developInput(for: develop(ProfileLibrary.monoStockID))
        XCTAssertTrue(mono.mono)
        XCTAssertEqual(mono.ratios, BaseRatios(rg: 1, bg: 1))
    }
}

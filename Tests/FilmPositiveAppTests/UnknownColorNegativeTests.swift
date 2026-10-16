import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The generic color negative row and the profile behind it.
///
/// The row reads "Color Negative", sidecar value still "generic". That literal renders
/// through `unknown-color-negative`, not one manufacturer's numbers for one specific
/// emulsion. It carries no dye gammas and renders on neutral 1/1/1, no film opinion.
final class UnknownColorNegativeTests: XCTestCase {

    private func library() throws -> ProfileLibrary { try ProfileLibrary.bundled() }

    /// The entry itself. It carries no dye gammas at all, so it renders on neutral 1/1/1: no
    /// film opinion, equal channel contrast.
    func testTheGenericBackingProfileIsNeutral() throws {
        let library = try self.library()
        let unknown = try XCTUnwrap(library.films["unknown-color-negative"])
        XCTAssertEqual(ProfileLibrary.genericStockID, unknown.id)
        XCTAssertEqual(unknown.name, "Unknown color negative")
        XCTAssertTrue(unknown.isHidden, "it backs the generic row, it is not a row")
        XCTAssertFalse(unknown.isMono)
        XCTAssertNil(unknown.datasheetDyeGamma, "the unknown colour negative carries a film opinion")
        XCTAssertFalse(unknown.isDatasheet)
        XCTAssertEqual(unknown.dyeGamma, .neutral)
        XCTAssertEqual(library.resolveFilm("generic").dyeGamma, .neutral)
        XCTAssertTrue(unknown.note?.lowercased().contains("no film opinion, equal channel contrast") ?? false,
                      unknown.note ?? "no note")
    }

    /// Nothing in it at all but its name and its note, asserted over the bytes rather than
    /// over the typed fields.
    func testTheEntryCarriesNothingButItsNameAndNote() throws {
        let library = try self.library()
        let json = try Data(contentsOf: library.root.appendingPathComponent("films/unknown-color-negative.json"))
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any]).keys),
                       ["id", "name", "hidden", "note"])
        let text = try XCTUnwrap(String(data: json, encoding: .utf8)).lowercased()
        XCTAssertFalse(text.contains("mean"), "the mean survived in the prose")
    }

    /// The literal "generic" still resolves, which is what makes this a no-migration
    /// change: every sidecar already written names it. An id the library does not know
    /// lands in the same place, because an unnamed film and an unrecognised one are the
    /// same situation.
    func testTheGenericLiteralAndAnUnknownIDBothResolveHere() throws {
        let library = try self.library()
        let generic = library.resolveFilm(ProfileLibrary.genericStockName)
        XCTAssertEqual(generic.profile.id, "unknown-color-negative")
        XCTAssertEqual(generic.dyeGamma, .neutral)

        let unknown = library.resolveFilm("no-such-film-2026")
        XCTAssertEqual(unknown.profile.id, "unknown-color-negative")
        XCTAssertTrue(unknown.fellBackToGeneric)

        // A named stock is untouched by all of this and still renders on its own numbers.
        let gold = library.resolveFilm("kodak-gold-200")
        XCTAssertEqual(gold.dyeGamma, DyeGamma(r: 0.954, g: 1, b: 1.094))
        XCTAssertNotEqual(gold.dyeGamma, generic.dyeGamma)
    }

    /// The unknown film is an ordinary color stock to the base ladder: the film edge when it
    /// is found, a picked base when there is one, and none when the edge search is off.
    func testTheUnknownFilmHonoursTheEdgeSwitchLikeAnyOtherStock() throws {
        let library = try self.library()
        var develop = DevelopSettings(stock: ProfileLibrary.genericStockName, tone: .none,
                                      autoBalance: false, base: BaseSettings(mode: .anchor))
        let off = BaseResolver.resolve(develop: develop, profiles: library,
                                       measureRebate: { XCTFail("off must not measure"); return nil })
        XCTAssertEqual(off.source, .off)
        XCTAssertEqual(off.ratios, BaseResolver.neutral)

        develop.autoBalance = true
        let on = BaseResolver.resolve(develop: develop, profiles: library,
                                      measureRebate: { [12000, 25000, 18000] })
        XCTAssertEqual(on.source, .edge(BaseRatios(rg: 0.48, bg: 0.72)))
    }

    /// A frame developed with no film name recorded gets the generic stock with the flag
    /// already true, so the sidecar says what the render does.
    func testInitialDevelopWritesTheGenericStockWithAutoBalanceOn() throws {
        let library = try self.library()
        let develop = library.initialDevelop(capture: nil)
        XCTAssertEqual(develop.stock, ProfileLibrary.genericStockName)
        XCTAssertTrue(develop.autoBalance)
    }

    /// The picker holds ONE generic row and the backing profile is not a second one. It
    /// would otherwise arrive as a datasheet stock named "Unknown color negative", which is
    /// the same choice twice under two ids, and the one the user picked would decide
    /// whether the sidecar said "generic" or a profile id.
    @MainActor
    func testThePickerHoldsExactlyOneGenericRowAndNotTheBackingProfile() throws {
        let library = try self.library()
        let choices = StockChoices.list(from: library, current: nil)

        let generics = choices.filter { $0.kind == .generic }
        XCTAssertEqual(generics.count, 1)
        let row = try XCTUnwrap(generics.first)
        XCTAssertEqual(row.id, "generic")
        XCTAssertEqual(row.name, "Color Negative")
        XCTAssertEqual(choices.first?.id, "generic", "the color negative row leads the list")

        XCTAssertFalse(choices.contains { $0.id == "unknown-color-negative" })
        XCTAssertFalse(choices.contains { $0.name == "Unknown color negative" })
        // And it stays out when it is the current selection, because the current value is
        // the literal "generic" and that row is already there.
        let withCurrent = StockChoices.list(from: library, current: "generic")
        XCTAssertEqual(withCurrent.filter { $0.kind == .generic }.count, 1)
        XCTAssertFalse(withCurrent.contains { $0.id == "unknown-color-negative" })
    }
}

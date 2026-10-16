import XCTest
import FilmSidecar
@testable import FilmPositiveCore

final class ProfileTests: XCTestCase {
    func testBundledLibraryLoads() throws {
        let lib = try ProfileLibrary.bundled()
        XCTAssertGreaterThanOrEqual(lib.films.count, 3)
        XCTAssertNotNil(lib.films["kodak-gold-200"])
        XCTAssertNotNil(lib.films[ProfileLibrary.genericStockID])
        XCTAssertNotNil(lib.films[ProfileLibrary.monoStockID])
        XCTAssertGreaterThan(lib.aliases.count, 20)
    }

    /// Gold 200 ships the manufacturer's numbers, not ones measured off a roll: the dye
    /// gammas off Kodak's own characteristic curve in E-7022, fitted over one log H window
    /// shared by all three channels, and no base pair at all.
    func testGold200DatasheetValues() throws {
        let lib = try ProfileLibrary.bundled()
        let g = try XCTUnwrap(lib.films["kodak-gold-200"])
        XCTAssertTrue(g.isDatasheet)
        XCTAssertFalse(g.isMeasured)
        XCTAssertEqual(g.datasheetDyeGamma?.dyeGamma, DyeGamma(r: 0.957, g: 1, b: 1.094))
        XCTAssertEqual(g.dyeGamma, DyeGamma(r: 0.957, g: 1, b: 1.094))
        XCTAssertEqual(g.datasheetDyeGamma?.source.publication, "Kodak E-7022 (06-23)")
        XCTAssertEqual(g.maker, "Kodak")
        XCTAssertFalse(g.isMono)
        // The fixed-window fit, not the adaptive one. The adaptive fit picks blue's own
        // steepest sliver for this stock and returns 1.233, which is the number this
        // assertion exists to keep out.
        XCTAssertEqual(try XCTUnwrap(g.datasheetDyeGamma).b, 1.094, accuracy: 1e-9)
    }

    // One Black & White choice, neutral by physics
    func testMonoIsOneChoiceAndNeutral() throws {
        let lib = try ProfileLibrary.bundled()
        let bw = lib.mono
        XCTAssertTrue(bw.isMono)
        XCTAssertEqual(bw.dyeGamma, .neutral)
        let monoFilms = lib.films.values.filter { $0.isMono }
        XCTAssertEqual(monoFilms.count, 1, "exactly one B&W profile ships")
        for alias in ["tri-x", "arista-400", "ilford-hp5-plus", "kodak-tmax-400", "mono"] {
            XCTAssertEqual(lib.resolveFilm(alias).profile.id, "bw-generic", alias)
        }
    }

    // The never-fail fallback
    func testResolutionFallsBackToGeneric() throws {
        let lib = try ProfileLibrary.bundled()
        let generic = lib.resolveFilm("generic")
        XCTAssertEqual(generic.profile.id, ProfileLibrary.genericStockID)
        XCTAssertFalse(generic.fellBackToGeneric)

        // A name with no profile and no alias, chosen so it cannot become a real stock by
        // accident.
        let unknown = lib.resolveFilm("no-such-stock-9000")
        XCTAssertEqual(unknown.profile.id, ProfileLibrary.genericStockID)
        XCTAssertTrue(unknown.fellBackToGeneric)
        XCTAssertEqual(unknown.requested, "no-such-stock-9000")
        XCTAssertNil(lib.films["no-such-stock-9000"])
        XCTAssertNil(lib.aliases["no-such-stock-9000"])

        let aliased = lib.resolveFilm("cinestill-800t")
        XCTAssertEqual(aliased.profile.id, "kodak-vision3-500t")
    }

    func testNoVendorDataInBundle() throws {
        let lib = try ProfileLibrary.bundled()
        let e = FileManager.default.enumerator(atPath: lib.root.path)!
        let hits = (e.allObjects as! [String]).filter { $0.lowercased().contains("filmlab") }
        XCTAssertEqual(hits, [])
    }
}

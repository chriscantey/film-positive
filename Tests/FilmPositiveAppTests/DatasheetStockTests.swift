import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The shipped stock list and where its numbers come from.
final class DatasheetStockTests: XCTestCase {

    private func library() throws -> ProfileLibrary { try ProfileLibrary.bundled() }

    /// Every shipped datasheet stock carries the publication its numbers came from and the
    /// URL of that sheet, inside its dye gammas' source.
    ///
    /// The sha256 of each sheet does not ship, because the app never reads it.
    func testEveryShippedDatasheetIsNamedAndLinked() throws {
        let films = try library().films.values.filter { $0.datasheetDyeGamma != nil }
        // Eleven stocks. The floor is deliberately a floor, so a stock disappearing by
        // accident still fails, and it moves only when someone decides a stock should go.
        XCTAssertGreaterThanOrEqual(films.count, 11, "the shipped datasheet set shrank")
        for film in films {
            let s = try XCTUnwrap(film.datasheetDyeGamma).source
            XCTAssertFalse(s.publication.isEmpty, film.id)
            XCTAssertFalse(s.method.isEmpty, film.id)
            if film.isHidden {
                // The one DERIVED entry: the generic row's backing profile, which names no
                // PDF because it did not come out of one.
                XCTAssertEqual(s.publication, "derived", film.id)
                XCTAssertNil(s.url, "\(film.id) is derived and cannot link a sheet")
            } else {
                XCTAssertTrue(s.url?.hasPrefix("https://") ?? false, film.id)
            }
        }
    }

    /// No FilmLab data is in this repo to compare against, by design, so the in-repo
    /// assertion is the one that can be made here: every datasheet names a manufacturer
    /// publication and the file it came from, and nothing in the tree mentions FilmLab outside
    /// the flag that declares its absence. The element-for-element comparison against
    /// FilmLab's own arrays was run once outside the repo: 217 vendor arrays, zero matches,
    /// and not one of them even has 31 points.
    func testNothingShippedClaimsAVendorSource() throws {
        let library = try self.library()
        for film in library.films.values {
            let json = try Data(contentsOf: library.root.appendingPathComponent("films/\(film.id).json"))
            let text = try XCTUnwrap(String(data: json, encoding: .utf8)).lowercased()
                .replacingOccurrences(of: "filmlabderived", with: "")
            XCTAssertFalse(text.contains("filmlab"), "\(film.id) mentions FilmLab")
            if film.datasheetDyeGamma != nil {
                XCTAssertTrue(text.contains("publication"), "\(film.id) carries dye gammas with no publication")
                XCTAssertTrue(text.contains("method"), "\(film.id) carries dye gammas with no method")
            }
        }
    }

    /// Every shipped COLOR stock carries dye gammas read off its own published
    /// characteristic curve, so no shipped entry borrows. The borrowing path is still in the
    /// code and still correct, because a stock whose sheet publishes a mask curve and no
    /// characteristic curve can be added at any time. None is shipped, and that is what this
    /// pins.
    @MainActor
    func testEveryShippedColourStockCarriesItsOwnPublishedGammas() throws {
        let library = try self.library()
        let choices = StockChoices.list(from: library, current: nil)
        let kinds = Set(choices.map(\.kind))
        XCTAssertTrue(kinds.contains(.generic))
        XCTAssertTrue(kinds.contains(.mono))
        XCTAssertTrue(kinds.contains(.curve(measured: false)))
        XCTAssertFalse(kinds.contains(.curve(measured: true)),
                       "no shipped stock carries a measured pair")

        // Said again against the files rather than against the picker, because the picker
        // filters and the claim is about what ships.
        let generic = library.resolveFilm("generic")
        // A stock offered with no curve (Azure) is the declared exception: it has nothing of
        // its own by construction. The rule below is not loosened for it, it is
        // replaced by a stricter one in `testAListedStockCarriesNothingOfItsOwn`.
        for film in library.films.values
        where !film.isMono && film.activities == nil && film.id != ProfileLibrary.genericStockID {
            XCTAssertNotNil(film.datasheetDyeGamma, "\(film.id) has no published dye gammas")
            let r = library.resolveFilm(film.id)
            XCTAssertFalse(r.fellBackToGeneric, "\(film.id) has to resolve to itself")
            XCTAssertEqual(r.dyeGamma, film.datasheetDyeGamma?.dyeGamma, film.id)
            XCTAssertNotEqual(r.dyeGamma, generic.dyeGamma,
                              "\(film.id) is rendering on the generic stock's gammas")
        }

        // Portra 400's dye gammas come off Kodak E-4050's own plot.
        let portra = try XCTUnwrap(choices.first { $0.id == "kodak-portra-400" })
        XCTAssertEqual(portra.kind, .curve(measured: false))
        let resolved = library.resolveFilm("kodak-portra-400")
        XCTAssertEqual(resolved.profile.id, "kodak-portra-400")
        XCTAssertEqual(resolved.profile.datasheetDyeGamma?.dyeGamma, DyeGamma(r: 0.978, g: 1, b: 1.15))

        // Gold 200: still itself, on the anchored window since pass 3 (red 0.957 before).
        let goldChoice = try XCTUnwrap(choices.first { $0.id == "kodak-gold-200" })
        XCTAssertEqual(goldChoice.kind, .curve(measured: false))
        let gold = library.resolveFilm("kodak-gold-200")
        XCTAssertEqual(gold.dyeGamma, DyeGamma(r: 0.954, g: 1, b: 1.094))
        XCTAssertNotNil(gold.profile.datasheetDyeGamma?.source.url)
    }

    /// The rule is "has a curve". A profile whose pair was measured
    /// off a chart goes through the same path as a published one, and the picker says
    /// where the pair came from instead of crediting a sheet.
    func testAMeasuredCurveIsACurveStockAndSaysSo() throws {
        let json = #"{"id":"lucky-color-200","name":"Lucky Color 200","maker":"Lucky","datasheetDyeGamma":{"r":0.97,"g":1,"b":1.08,"source":{"publication":"measured","method":"chart, six grey patches"}}}"#
        let measured = try JSONDecoder().decode(FilmProfile.self, from: Data(json.utf8))
        XCTAssertTrue(measured.isDatasheet, "a measured curve is a curve")
        XCTAssertTrue(measured.isMeasured)
        XCTAssertEqual(measured.dyeGamma, DyeGamma(r: 0.97, g: 1, b: 1.08))
        let gold = try XCTUnwrap(try library().films["kodak-gold-200"])
        XCTAssertFalse(gold.isMeasured)
    }

    /// A stock with no dye gammas of its own falls back to the generic stock's, which are
    /// neutral 1/1/1, no film opinion. Exercised directly on a stripped copy so the borrow is
    /// tested on a stock known to have nothing.
    func testAStockWithNoPublishedCurveBorrowsTheNeutralGeneric() throws {
        let library = try self.library()
        let generic = library.resolveFilm("generic")
        XCTAssertEqual(generic.dyeGamma, .neutral, "the unknown colour negative has no film opinion")
        XCTAssertNil(generic.profile.datasheetDyeGamma)

        var stripped = try XCTUnwrap(library.films["kodak-portra-400"])
        stripped.datasheetDyeGamma = nil
        XCTAssertFalse(stripped.isDatasheet)
        XCTAssertEqual(stripped.dyeGamma, .neutral,
                       "a profile's own stored gamma is neutral when it has none of its own")
    }

    /// The shape itself, in the fast test filter, forever: a shipped film profile carries
    /// only the keys the app reads or presents. That also keeps out every number measured
    /// from somebody's roll, since none of those keys is in the shape.
    ///
    /// Read as raw JSON rather than through `FilmProfile`, because a decoder only sees the
    /// fields it declares and the point is to catch a field nobody declared.
    func testNoShippedFilmCarriesAKeyOutsideTheShape() throws {
        let dir = try library().root.appendingPathComponent("films")
        let allowed: Set<String> = ["id", "name", "maker", "datasheetDyeGamma", "whiteDensity", "activities", "note", "hidden"]
        let allowedSource: Set<String> = ["publication", "method", "url"]
        var checked = 0
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".json") {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
            for key in Set(json.keys).subtracting(allowed).sorted() { offenders.append("\(name) carries \(key)") }
            if let gamma = json["datasheetDyeGamma"] as? [String: Any] {
                for key in Set(gamma.keys).subtracting(["r", "g", "b", "source"]).sorted() {
                    offenders.append("\(name) carries datasheetDyeGamma.\(key)")
                }
                let source = gamma["source"] as? [String: Any] ?? [:]
                for key in Set(source.keys).subtracting(allowedSource).sorted() {
                    offenders.append("\(name) carries datasheetDyeGamma.source.\(key)")
                }
            }
            checked += 1
        }
        XCTAssertEqual(offenders, [])
        XCTAssertGreaterThanOrEqual(checked, 11, "the walk found almost nothing, so it proves nothing")
    }

    /// The measured base pair off one UltraMax roll is not in the source tree for stocks to
    /// borrow. An uncorrected render is honest, a borrowed measurement is not.
    func testTheOldBorrowedPairIsGone() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        var scanned = 0
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for number in ["0.4528", "0.7650"] where text.contains(number) {
                offenders.append("\(url.lastPathComponent) still carries \(number)")
            }
        }
        XCTAssertEqual(offenders, [])
        XCTAssertGreaterThan(scanned, 20, "the walk found almost no Swift files, so it proves nothing")
    }

    /// A real profile file beats an alias. Applied first, the
    /// `kodak-portra-400 -> ektacolor-pro-400` alias would send every Portra 400 frame to a
    /// name with no file, and it would render through the generic path.
    func testARealProfileBeatsAnAlias() throws {
        let library = try self.library()
        XCTAssertEqual(library.aliases["kodak-portra-400"], "ektacolor-pro-400")
        XCTAssertNil(library.films["ektacolor-pro-400"], "this test is about a name with no file")
        XCTAssertEqual(library.resolveFilm("kodak-portra-400").profile.id, "kodak-portra-400")
        // and the Eastman name still resolves, through the alias that points the other way
        XCTAssertEqual(library.resolveFilm("ektacolor-pro-400").profile.id, "kodak-portra-400")
        XCTAssertEqual(library.resolveFilm("ektacolor-pro-800").profile.id, "kodak-portra-800")
    }

    /// Remjet-free repackages resolve to the Kodak curve of the stock they are, and
    /// none has a profile of its own.
    func testRemjetFreeRepackagesResolveToTheirKodakStock() throws {
        let library = try self.library()
        let expected = [
            "cinestill-50d": "kodak-vision3-50d",
            "cinestill-800t": "kodak-vision3-500t",
            "kodak-vision3-250d-remjet-removed": "kodak-vision3-250d",
        ]
        for (from, to) in expected {
            XCTAssertEqual(library.resolveFilm(from).profile.id, to, from)
            XCTAssertNil(library.films[from], "\(from) must not have a profile of its own")
        }
        // A stock in the picker is a manufacturer datasheet, nothing interim. CineStill 400D
        // has no Kodak stock behind it (CineStill names no parent and it ships in 4x5), and
        // Lomography CN 400 is unproven UltraMax with no sheet, so neither resolves to anyone
        // else's curve.
        for gone in ["cinestill-400d", "lomography-cn-400"] {
            XCTAssertNil(library.aliases[gone], "\(gone) must not be aliased")
            XCTAssertEqual(library.resolveFilm(gone).profile.id, ProfileLibrary.genericStockID, gone)
        }
    }

    /// Every shipped stock has a manufacturer publication behind it, or is one of
    /// the paths that need none: black and white, the neutral unknown color negative, and
    /// a stock offered with no curve.
    func testEveryShippedStockHasAnOpenSource() throws {
        for film in try library().films.values {
            if film.isMono || film.activities != nil || film.id == ProfileLibrary.genericStockID { continue }
            XCTAssertNotNil(film.datasheetDyeGamma?.source.publication, "\(film.id) ships with no publication")
        }
    }

    /// The replacement rule for a listed stock, and it is stricter than the one it stands
    /// in for: a stock offered without its maker's curves must carry NOTHING of its own, so
    /// the row cannot quietly acquire a number nobody published. It renders on exactly the
    /// generic stock's gammas, which is what its caption promises.
    func testAListedStockCarriesNothingOfItsOwn() throws {
        let library = try self.library()
        let listed = library.films.values.filter { !$0.isHidden && !$0.isMono && $0.datasheetDyeGamma == nil }
        XCTAssertFalse(listed.isEmpty, "no listed stock: this rule has stopped being checked")
        let generic = library.resolveFilm("generic")
        for film in listed {
            XCTAssertNil(film.datasheetDyeGamma, "\(film.id) carries dye gammas nobody published")
            XCTAssertFalse(film.isDatasheet, "\(film.id) claims to be a datasheet stock")
            XCTAssertEqual(library.resolveFilm(film.id).dyeGamma, generic.dyeGamma,
                           "\(film.id) does not render on the generic stock its caption promises")
        }
    }

    /// The picker offers manufacturer-backed stocks only. Lomography 800 has no sheet
    /// anywhere (nobody has profiled the CN 800-1 emulsion), so it is out of the list and
    /// is left for the user to import a profile for. The alias stays, so a sidecar that already
    /// names it keeps resolving and keeps being selectable.
    ///
    /// It is carried as UNPROFILED, and that is the honest label rather than a gap: its
    /// alias target `kodak-ultra-max-800` ships no profile file, so the frame really does
    /// render through the generic path. The target having no file is what keeps it out, and
    /// that is checked here.
    @MainActor
    func testAnAliasWithNoFileBehindItIsOutOfThePickerButStillSelectable() throws {
        let library = try self.library()
        XCTAssertEqual(library.aliases["lomography-cn-800"], "kodak-ultra-max-800")
        XCTAssertNil(library.films["kodak-ultra-max-800"], "this test is about an alias with no file behind it")
        let list = StockChoices.list(from: library, current: nil)
        XCTAssertFalse(list.contains { $0.id == "lomography-cn-800" }, "an alias with no file behind it is offered")

        let carried = StockChoices.list(from: library, current: "lomography-cn-800")
        let entry = try XCTUnwrap(carried.first { $0.id == "lomography-cn-800" },
                                  "a sidecar naming it would blank the picker")
        XCTAssertEqual(entry.kind, .unprofiled)
        XCTAssertEqual(entry.name, "Lomography 800")
        XCTAssertEqual(library.resolveFilm("lomography-cn-800").profile.id, ProfileLibrary.genericStockID)
        XCTAssertTrue(library.resolveFilm("lomography-cn-800").fellBackToGeneric)
    }

    /// Cross-processing is an alias property, not a film property: the sheet is the
    /// emulsion's and the chemistry is not. The three Reflx Lab stocks are Vision3 with an
    /// anti-halation undercoat in place of remjet, respooled for still cameras and souped
    /// in C-41, and each one points at the ECN-2 sheet for its own emulsion.
    func testCrossProcessedAliasesAreFlagged() throws {
        let library = try self.library()
        for (id, emulsion) in [("reflx-lab-50d-ahu", "kodak-vision3-50d"),
                               ("reflx-lab-320d-ahu", "kodak-vision3-250d"),
                               ("reflx-lab-640t-ahu", "kodak-vision3-500t")] {
            let r = library.resolveFilm(id)
            XCTAssertEqual(r.profile.id, emulsion, id)
            XCTAssertTrue(r.crossProcessed, "\(id) is cross-processed")
            XCTAssertFalse(r.fellBackToGeneric, id)
        }
        XCTAssertTrue(library.resolveFilm("cinestill-800t").crossProcessed)
        XCTAssertTrue(library.resolveFilm("cinestill-50d").crossProcessed)
        XCTAssertFalse(library.resolveFilm("kodak-portra-400").crossProcessed)
        XCTAssertFalse(library.resolveFilm("generic").crossProcessed)
        XCTAssertFalse(library.resolveFilm("ektacolor-pro-400").crossProcessed,
                       "a rename is not a cross-process")
    }

    /// And the picker's entry says so, in its kind, for the entries that are in it.
    @MainActor
    func testTheCrossProcessedCaptionSaysWhatHappenedToTheFilm() throws {
        let library = try self.library()
        let list = StockChoices.list(from: library, current: nil)
        for id in ["cinestill-800t", "reflx-lab-50d-ahu", "reflx-lab-320d-ahu",
                   "reflx-lab-640t-ahu"] {
            let entry = try XCTUnwrap(list.first { $0.id == id }, "\(id) is missing from the picker")
            guard case .alias(_, let crossProcessed) = entry.kind else {
                return XCTFail("\(id) is not an alias: \(entry.kind)")
            }
            XCTAssertTrue(crossProcessed, "\(id) is not marked cross-processed")
        }
        let ektacolor = try XCTUnwrap(list.first { $0.id == "ektacolor-pro-400" })
        XCTAssertEqual(ektacolor.kind, .alias(target: "Kodak Portra 400", crossProcessed: false))
        XCTAssertEqual(try XCTUnwrap(list.first { $0.id == "reflx-lab-320d-ahu" }).name, "Reflx Lab 320D AHU")
        XCTAssertEqual(try XCTUnwrap(list.first { $0.id == "reflx-lab-640t-ahu" }).name, "Reflx Lab 640T AHU")
        XCTAssertEqual(try XCTUnwrap(list.first { $0.id == "reflx-lab-50d-ahu" }).name, "Reflx Lab 50D AHU")
    }
}

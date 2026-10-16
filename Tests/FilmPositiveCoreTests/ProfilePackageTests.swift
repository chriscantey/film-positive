import XCTest
@testable import FilmPositiveCore

/// A profile exports to one open JSON file and imports back with its fields intact,
/// so a stock somebody measures can be shared. And the two refusals that matter: a
/// FilmLab-derived profile and dye gammas that do not say where they came from never enter
/// this app.
final class ProfilePackageTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-profile-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A profile in the current shape, measured off a chart, plus one
    /// key this build does not read, which is what a file from a newer build looks like.
    private var sample: [String: Any] {
        [
            "id": "kodak-gold-200",
            "name": "Kodak Gold 200",
            "maker": "Kodak",
            "datasheetDyeGamma": [
                "r": 0.739, "g": 1.0, "b": 1.103,
                "source": ["publication": "measured",
                           "method": "ColorChecker Classic Mini, six grey patches, linear fit"],
            ],
            "note": "Fit from one chart frame.",
            "fromANewerBuild": "2026-09-11T23:23:17.949Z",
        ]
    }

    /// The round trip that matters: everything in the file survives, including a key the
    /// engine never reads. A typed re-encode would drop it, and nobody would notice until a
    /// shared profile lost something its author put there.
    func testRoundTripKeepsEveryFieldAndIsByteStable() throws {
        let first = try ProfilePackage.encode(sample)
        let (object, profile) = try ProfilePackage.decode(first)
        XCTAssertEqual(profile.id, "kodak-gold-200")
        XCTAssertEqual(profile.datasheetDyeGamma?.r, 0.739)
        XCTAssertEqual(profile.datasheetDyeGamma?.source.publication, "measured")
        XCTAssertEqual(profile.maker, "Kodak")
        XCTAssertEqual(object["fromANewerBuild"] as? String, sample["fromANewerBuild"] as? String)

        let second = try ProfilePackage.encode(object)
        XCTAssertEqual(first, second, "two exports of the same profile have to be byte-equal")
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"datasheetDyeGamma\""))?.lowerBound ?? text.endIndex,
                          try XCTUnwrap(text.range(of: "\"name\""))?.lowerBound ?? text.startIndex, "keys are sorted")
    }

    /// The check has to accept the honest declaration. Every profile this app ships carries
    /// `"filmlabDerived": false`, and a plain text search for "filmlab" over the file
    /// would reject all of them.
    func testTheHonestDeclarationIsNotMistakenForTheThingItDenies() throws {
        XCTAssertNil(ProfilePackage.mentionsFilmLab(sample))
        XCTAssertNotNil(ProfilePackage.mentionsFilmLab(["notes": "traced from FilmLab"]))
        XCTAssertNotNil(ProfilePackage.mentionsFilmLab(["filmlabSpectra": [1, 2, 3]]))
        XCTAssertNotNil(ProfilePackage.mentionsFilmLab(["provenance": ["inputs": ["filmlab-vendor"]]]))
    }

    func testAFilmLabDerivedProfileIsRefusedTwoWays() throws {
        var flagged = sample
        flagged["provenance"] = ["source": "vendor", "filmlabDerived": true]
        XCTAssertThrowsError(try ProfilePackage.decode(try ProfilePackage.encode(flagged))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .filmlabDerived("its provenance says so"))
        }

        // The flag is a claim, so the text is checked too: this one lies about itself.
        var hidden = sample
        hidden["note"] = "digitized from the FilmLab vendor pack"
        XCTAssertThrowsError(try ProfilePackage.decode(try ProfilePackage.encode(hidden))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .filmlabDerived("another app is named in note"))
        }
    }

    func testUnsourcedGammasOrNoIdIsRefused() throws {
        var noSource = sample
        noSource["datasheetDyeGamma"] = ["r": 0.739, "g": 1.0, "b": 1.103]
        XCTAssertThrowsError(try ProfilePackage.decode(try ProfilePackage.encode(noSource))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .noSource)
        }
        var noMethod = sample
        noMethod["datasheetDyeGamma"] = ["r": 0.739, "g": 1.0, "b": 1.103, "source": ["publication": "measured"]]
        XCTAssertThrowsError(try ProfilePackage.decode(try ProfilePackage.encode(noMethod))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .noSource)
        }
        // A profile with no numbers has nothing to source, and loads.
        var numberless = sample
        numberless["datasheetDyeGamma"] = nil
        XCTAssertNoThrow(try ProfilePackage.decode(try ProfilePackage.encode(numberless)))

        var noID = sample
        noID["id"] = ""
        XCTAssertThrowsError(try ProfilePackage.decode(try ProfilePackage.encode(noID))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .missing("id"))
        }

        var slide = sample
        slide["process"] = "E-6"
        XCTAssertThrowsError(try ProfilePackage.decode(try ProfilePackage.encode(slide))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .unsupportedProcess("E-6"))
        }

        XCTAssertThrowsError(try ProfilePackage.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ProfilePackage.PackageError, .notAnObject)
        }
    }

    /// Install writes the canonical file into the user's own folder, and a library loaded
    /// afterwards uses it in place of the shipped profile with the same id.
    func testAnInstalledProfileOverridesTheShippedOne() throws {
        var edited = sample
        edited["name"] = "Kodak Gold 200 (my roll)"
        edited["datasheetDyeGamma"] = ["r": 0.700, "g": 1.0, "b": 1.200,
                                       "source": ["publication": "measured", "method": "chart"]]
        let url = try ProfilePackage.install(try ProfilePackage.encode(edited), into: scratch)
        XCTAssertEqual(url.lastPathComponent, "kodak-gold-200.json")

        setenv("FP_USER_PROFILES", scratch.path, 1)
        defer { unsetenv("FP_USER_PROFILES") }
        let library = try ProfileLibrary.bundled()
        XCTAssertEqual(library.films["kodak-gold-200"]?.name, "Kodak Gold 200 (my roll)")
        XCTAssertEqual(library.films["kodak-gold-200"]?.datasheetDyeGamma?.b, 1.200)
        // and the shipped stocks are all still there
        XCTAssertNotNil(library.films["kodak-ultramax-400"])
        XCTAssertNotNil(library.films[ProfileLibrary.monoStockID])

        // export gives back exactly what was installed
        let exported = try ProfilePackage.export("kodak-gold-200", from: library)
        XCTAssertEqual(exported, try Data(contentsOf: url))
    }

    /// A broken file in the user folder cannot take the library down with it: the shipped
    /// stocks have to keep working whatever somebody dropped in there.
    func testABrokenUserProfileIsSkipped() throws {
        try Data("{ not json".utf8).write(to: scratch.appendingPathComponent("broken.json"))
        var noSource = sample
        noSource["datasheetDyeGamma"] = ["r": 0.739, "g": 1.0, "b": 1.103]
        noSource["id"] = "kodak-ultramax-400"
        try ProfilePackage.encode(noSource).write(to: scratch.appendingPathComponent("kodak-ultramax-400.json"))

        setenv("FP_USER_PROFILES", scratch.path, 1)
        defer { unsetenv("FP_USER_PROFILES") }
        let library = try ProfileLibrary.bundled()
        XCTAssertNotNil(library.films["kodak-ultramax-400"], "the shipped profile has to survive a bad override")
        XCTAssertNotEqual(library.films["kodak-ultramax-400"]?.name, "Kodak Gold 200")
    }

    /// Exporting a shipped profile gives a file another copy of the app will accept, which
    /// is the whole point of the format.
    func testAShippedProfileExportsAndReimports() throws {
        setenv("FP_USER_PROFILES", "", 1)
        defer { unsetenv("FP_USER_PROFILES") }
        let library = try ProfileLibrary.bundled()
        let data = try ProfilePackage.export("kodak-ultramax-400", from: library)
        let (object, profile) = try ProfilePackage.decode(data)
        XCTAssertEqual(profile.id, "kodak-ultramax-400")
        XCTAssertNotNil((object["datasheetDyeGamma"] as? [String: Any])?["source"],
                        "a shipped profile carries the source of its numbers into the share")
        XCTAssertEqual(try ProfilePackage.encode(object), data)
        XCTAssertThrowsError(try ProfilePackage.export("no-such-stock", from: library))
    }
}

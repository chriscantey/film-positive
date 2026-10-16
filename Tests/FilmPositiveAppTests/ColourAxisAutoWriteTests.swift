import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// NOTHING AUTOMATIC WRITES THE COLOUR AXES.
///
/// The axes default to no effect and stay there until a person moves them. That is the
/// clause that makes them safe to ship: every frame already in the library renders in the
/// next build exactly as it rendered in this one, and no auto step, no profile, no look and
/// no default can put a color cast on a picture nobody asked for.
///
/// Stated as a rule it is a promise. Stated here it is a test, in both directions, because
/// the two failures are different and only one of them is obvious. An automatic step that
/// SETS an axis is loud, and somebody would notice. An automatic step that RESETS one is
/// silent: the person's grade simply is not there any more and the frame looks like it was
/// never graded.
final class ColourAxisAutoWriteTests: XCTestCase {

    private let graded = ColourAxes(warm: 7, green: -4)

    /// A real file on disk, because a sidecar records the provenance of the image it
    /// belongs to and `SidecarStore.source` is the only honest way to make one.
    private var image: URL!

    override func setUpWithError() throws {
        image = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axes-\(UUID().uuidString).CR2")
        try Data(repeating: 0x42, count: 2048).write(to: image)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: image) }

    private func sidecar(_ axes: ColourAxes) throws -> Sidecar {
        var s = Sidecar(source: try SidecarStore.source(for: image))
        var d = DevelopSettings(stock: "generic",
                                tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        d.colourAxes = axes
        s.develop = d
        return s
    }

    private func bare() throws -> Sidecar {
        Sidecar(source: try SidecarStore.source(for: image))
    }

    // MARK: the default

    /// The type's own default, which is what every construction site that does not mention
    /// the axes gets.
    func testTheDefaultIsNoEffect() {
        XCTAssertTrue(ColourAxes().isIdentity)
        XCTAssertTrue(ColourAxes.identity.isIdentity)
        XCTAssertEqual(ColourAxes().logOffsets.r, 0, accuracy: 0)
        XCTAssertEqual(ColourAxes().logOffsets.b, 0, accuracy: 0)
        let d = DevelopSettings(stock: "generic",
                                tone: .none, autoBalance: true, base: BaseSettings(mode: .anchor))
        XCTAssertTrue(d.colourAxes.isIdentity, "a develop layer arrived already graded")
    }

    /// The app's one automatic producer of a develop layer, over every shipped stock rather
    /// than over one. A profile that graded a frame on the user's behalf would be exactly
    /// the automatic write this forbids.
    func testNoShippedProfileGradesAFrameOnOpen() throws {
        let profiles = try ProfileLibrary.bundled()
        let stocks = Array(profiles.films.values)
        XCTAssertGreaterThan(stocks.count, 1, "no profiles loaded, so this asserts nothing")
        for film in stocks {
            let capture = CaptureInfo(film: film.name, filmMaker: nil)
            let d = profiles.initialDevelop(capture: capture)
            XCTAssertEqual(d.stock, ProfileLibrary.genericStockName, "\(film.id) picked by name")
            XCTAssertTrue(d.colourAxes.isIdentity,
                          "\(film.id) shipped a graded default: \(d.colourAxes)")
        }
        // And the no-capture path, which is what an unrecognised file gets.
        XCTAssertTrue(profiles.initialDevelop(capture: nil).colourAxes.isIdentity)
    }

    // MARK: every edit verb, in both directions

    /// The develop-layer verbs that are not the axes' own writer must leave a grade exactly
    /// where it was. `setBase` is the sharp one: the eyedropper writes a measured base pair
    /// into the same struct, and a version of it that rebuilt the layer rather than mutating
    /// one field would wipe the grade on every use of the dropper.
    func testNoOtherEditVerbTouchesAGradeThatIsThere() throws {
        let s = try sidecar(graded)
        let after: [(String, Sidecar)] = [
            ("setBase", SidecarEdits.setBase(s, BaseSettings(mode: .measured, measured: [1, 2, 3]))),
            ("setEnhance", SidecarEdits.setEnhance(s, EnhanceSettings.identity)),
            ("setGeometry", SidecarEdits.setGeometry(s, GeometrySettings(rotate: 90, flip: false,
                                                                        straightenDegrees: 0, crop: nil))),
            ("resetEnhance", SidecarEdits.resetEnhance(s)),
        ]
        for (name, out) in after {
            XCTAssertEqual(out.develop?.colourAxes, graded, "\(name) moved the grade")
        }
    }

    /// A LOOK cannot capture or write an axis, and the reason is structural rather than
    /// careful: a look holds `EnhanceSettings`, the axes live on `DevelopSettings`, and
    /// `applyLook` writes the enhance layer and the look id and nothing else. Asserted
    /// behaviourally so that a future look that grew a develop half would fail here.
    func testApplyingALookCannotReachTheGrade() throws {
        let s = try sidecar(graded)
        for look in ShippedLooks.all {
            let out = SidecarEdits.applyLook(s, look)
            XCTAssertEqual(out.develop?.colourAxes, graded, "look \(look.id) moved the grade")
        }
        // Including a monochrome look, which is the one that changes the most downstream.
        let mono = ShippedLooks.all.first(where: LookStore.isMonochrome)
        if let mono { XCTAssertEqual(SidecarEdits.applyLook(s, mono).develop?.colourAxes, graded) }
    }

    /// The one writer. Stated positively so that "nothing writes it" cannot be satisfied by
    /// a build where nothing CAN write it.
    func testTheAxesHaveExactlyOneWriterAndItWorks() throws {
        let s = try sidecar(.identity)
        let out = SidecarEdits.setColourAxes(s, graded)
        XCTAssertEqual(out.develop?.colourAxes, graded)
        // And back to neutral, which is what the reset in the row does.
        XCTAssertEqual(SidecarEdits.setColourAxes(out, .identity).develop?.colourAxes, .identity)
    }

    /// Anti: the writer does not invent a develop layer. A frame with no positive has
    /// nothing to grade, and building a layer around one axis would be guessing at the
    /// stock.
    func testTheWriterLeavesAnUndevelopedFrameAlone() throws {
        let bare = try bare()
        XCTAssertNil(SidecarEdits.setColourAxes(bare, graded).develop)
    }

    // MARK: the clipboard, which was writing them

    /// Copy Positive then Paste Positive carries the grade. A paste reproduces a state, and
    /// a graded positive whose grade did not travel is not that state.
    func testAPastedPositiveCarriesTheGrade() throws {
        let source = try sidecar(graded)
        let payload = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: source))
        let target = try XCTUnwrap(payload.applied(to: try sidecar(.identity)).develop)
        XCTAssertEqual(target.colourAxes, graded, "the grade did not travel with the positive")
    }

    /// The silent failure. The payload replaces the whole develop layer, so a payload that
    /// merely OMITTED the axes would reset the target's own grade to neutral without anybody
    /// asking for it.
    func testAPastedNEUTRALPositiveDoesNotSilentlyWipeTheTargetsGrade() throws {
        let payload = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: try sidecar(.identity)))
        let target = try XCTUnwrap(payload.applied(to: try sidecar(graded)).develop)
        XCTAssertEqual(target.colourAxes, .identity,
                       "pasting a neutral positive must set the target neutral, deliberately, not by omission")

        // The direction that matters: a paste of a section that is NOT the positive must
        // leave the grade completely alone.
        let enhanceOnly = try XCTUnwrap(FrameSettingsPayload.copying([.enhance], from: try sidecar(.identity)))
        XCTAssertEqual(enhanceOnly.applied(to: try sidecar(graded)).develop?.colourAxes, graded,
                       "a partial paste reached a section it does not carry")
    }

    /// A payload written before the axes existed decodes to neutral rather than failing,
    /// and a payload carrying a grade survives the pasteboard round trip.
    func testAnOlderPayloadDecodesToNeutralAndANewOneSurvivesTheRoundTrip() throws {
        let graded = try XCTUnwrap(FrameSettingsPayload.copying([.positive], from: try sidecar(self.graded)))
        let data = try JSONEncoder().encode(graded)
        let back = try JSONDecoder().decode(FrameSettingsPayload.self, from: data)
        XCTAssertEqual(back.positive?.settings.colourAxes, self.graded)

        // The same blob with the key removed, which is exactly what an older build wrote.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var positive = try XCTUnwrap(object["positive"] as? [String: Any])
        positive.removeValue(forKey: "colourAxes")
        object["positive"] = positive
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FrameSettingsPayload.self, from: older)
        XCTAssertEqual(decoded.positive?.settings.colourAxes, .identity)
        XCTAssertTrue(decoded.isUsable, "an older payload stopped being usable")
    }

    // MARK: the file
    //
    // Deliberately NOT here. Whether a neutral grade writes an attribute, whether a real
    // one survives an encode and a decode, and whether a sidecar from before the axes
    // existed reads as neutral are all claims about the FILE FORMAT, and the film-sidecar
    // package asserts all three in `ColourAxesTests` against a real file on disk. A second
    // copy at this level would not be a second check, it would be the same check in a place
    // that goes stale when the format moves.

    // MARK: the render path

    /// The gap that would have made every test above meaningless: `developInput` builds the
    /// kernel's input field by field, and `colourAxes` has a default, so leaving it out
    /// compiles and renders a neutral picture forever. A screen cannot catch it, because a
    /// missing grade and a grade nobody has set look identical.
    func testTheGradeOnTheSETTINGSReachesTheKERNEL() throws {
        let svc = CPURenderService(profiles: try ProfileLibrary.bundled())
        var d = DevelopSettings(stock: "generic",
                                tone: .none, autoBalance: false, base: BaseSettings(mode: .anchor))
        XCTAssertTrue(svc.developInput(for: d).colourAxes.isIdentity)
        d.colourAxes = graded
        XCTAssertEqual(svc.developInput(for: d).colourAxes, graded,
                       "the person's grade stopped at the settings and never reached the render")
    }
}

import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The funnel and write safety: two properties that pull in opposite directions, which is
/// why they are tested together in one file.
///
/// The funnel: EVERY path that writes anything to a frame with no develop layer
/// commits the effective defaults alongside its edit, so the file always says what the
/// picture does. The table below walks every mutating entry point rather than the ones
/// somebody remembered, and `testEveryMutatingSidecarEditHasARow` fails when a new entry
/// point is added to `SidecarEdits` with no row here.
///
/// Write safety: rendering writes NOTHING. Opening a folder and reading every frame's render
/// request must leave the sidecar store untouched, because browsing a folder must not start
/// writing sidecar files. The funnel is what makes the first EDIT write. Nothing else may.
final class DefaultsCommitTests: XCTestCase {

    // MARK: harness

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-defaults-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A model over `count` frames that carry no sidecar at all, which is the state a
    /// freshly copied roll is in.
    ///
    /// The real engine, because these tests read render REQUESTS rather than pixels and the
    /// requests are what the defaults feed. The real profile library is needed too: the
    /// defaults resolve a capture film name through it, so a stand-in would make every row
    /// below assert against nil.
    @MainActor
    private func freshModel(count: Int = 3) throws -> (AppModel, [Frame.ID], URL) {
        let roll = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let profiles = try ProfileLibrary.bundled()
        let model = AppModel(service: CPURenderService(profiles: profiles))
        // A test has no run loop event, so automatic grouping would swallow every explicit
        // group and one undo would unwind the whole test.
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(roll))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        XCTAssertEqual(try sidecars(in: roll).count, 0, "a fresh roll starts with no sidecars")
        return (model, ids, roll)
    }

    /// Every sidecar file in the folder, by name. The write-safety check is a file-level
    /// one on purpose: the folder starts with NO xmp at all, so any save whatsoever creates
    /// a file and cannot hide behind identical bytes.
    private func sidecars(in folder: URL) throws -> [String] {
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return all.filter { $0.hasSuffix("." + SidecarStore.ext) && !$0.hasPrefix(".") }.sorted()
    }

    // MARK: RIDER 1, the table

    /// One row per mutating entry point. `apply` is the edit exactly as a control makes it;
    /// `expectsDevelop` is false only for the deliberate exception.
    private struct Row {
        let name: String
        let apply: (AppModel, Frame.ID) -> Void
        let expectsDevelop: Bool
        /// False for a row that writes its OWN develop layer, which correctly overrides the
        /// defaults rather than committing them. The funnel still ran; its seed was simply
        /// replaced by the caller's value, which is the right answer for setDevelop.
        var expectsExactDefaults: Bool = true
        /// True for a row that writes something to disk WITHOUT committing a develop
        /// layer, which is geometry and only geometry: a rotation is written and
        /// the frame stays a negative. Ignored unless `expectsDevelop` is false, where the
        /// alternative is the resetDevelop row, which must write nothing at all.
        var writesGeometryOnly: Bool = false
        /// True for a Metadata row: the capture block is written and, like geometry, it
        /// leaves the frame a negative.
        var writesCaptureOnly: Bool = false
        /// The `SidecarEdits` entry point this row covers, for the completeness check.
        let covers: String
        /// What must be true of the committed layer when it is NOT the exact defaults,
        /// given (committed, effective defaults).
        ///
        /// A row-supplied check rather than one hardcoded assertion, because there are two
        /// different ways a row can differ from the defaults and only one of them
        /// was ever true here. `setDevelop` REPLACES the layer, so the caller's stock wins.
        /// `setBase` MODIFIES one field of it, so the defaults must all survive and only
        /// the base may differ. Asserting the first of those about the second would demand
        /// that an eyedropper pick also change the film stock.
        var check: (DevelopSettings, DevelopSettings) -> Void = { develop, _ in
            XCTAssertEqual(develop.stock, "kodak-ektar-100",
                           "the caller's own develop layer must win over the seed")
        }
    }

    @MainActor
    private func rows() -> [Row] {
        return [
            Row(name: "setDevelop", apply: { m, id in
                m.apply({ SidecarEdits.setDevelop($0, DevelopSettings(stock: "kodak-ektar-100",
                                                                      tone: .flat, autoBalance: true,
                                                                      base: BaseSettings(mode: .anchor))) },
                        to: id, actionName: "t")
            }, expectsDevelop: true, expectsExactDefaults: false, covers: "setDevelop"),

            Row(name: "setEnhance", apply: { m, id in
                m.apply({ SidecarEdits.setEnhance($0, EnhanceSettings(contrast: 0.42)) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "setEnhance"),

            // Levels and Curves are enhance writes, and commit the defaults as a slider does.
            Row(name: "setLevels", apply: { m, id in
                m.apply({ SidecarEdits.setLevels($0, Levels(gamma: 1.4)) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "setLevels"),
            Row(name: "setCurves", apply: { m, id in
                m.apply({ SidecarEdits.setCurves($0, Curves(rgb: CurvePoints(sanitising: [
                    CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]))) },
                        to: id, actionName: "t")
            }, expectsDevelop: true, covers: "setCurves"),
            // The lit Enhance Auto's click on a frame the wand wrote, as clearColorAuto below.
            Row(name: "clearAuto on a frame the Enhance Auto wrote", apply: { m, id in
                var e = EnhanceSettings(); e.blackPoint = 0.3
                m.apply({ SidecarEdits.applyAuto($0, e) }, to: id, actionName: "seed")
                m.apply({ SidecarEdits.clearAuto($0) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "clearAuto"),

            Row(name: "applyLook", apply: { m, id in
                let look = Look(id: "fp.test.look", name: "Test", blurb: "",
                                settings: EnhanceSettings(contrast: 0.3))
                m.apply({ SidecarEdits.applyLook($0, look) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "applyLook"),
            // The Enhance Auto's write commits the defaults exactly as a look does.
            Row(name: "applyAuto", apply: { m, id in
                var e = EnhanceSettings(); e.blackPoint = 0.3
                m.apply({ SidecarEdits.applyAuto($0, e) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "applyAuto"),
            // The Color Auto's write commits them too, and so does its lit click on a frame
            // that holds one, the same as resetEnhance below.
            Row(name: "applyColorAuto", apply: { m, id in
                m.apply({ SidecarEdits.applyColorAuto($0, WarmthTint(warmth: 0.12, tint: -0.04)) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "applyColorAuto"),
            Row(name: "clearColorAuto on a frame the Color Auto wrote", apply: { m, id in
                m.apply({ SidecarEdits.applyColorAuto($0, WarmthTint(warmth: 0.12, tint: -0.04)) }, to: id, actionName: "seed")
                m.apply({ SidecarEdits.clearColorAuto($0) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "clearColorAuto"),

            // The eyedropper. A pick on an undeveloped frame has to commit the defaults
            // beside the measured base, or the file would carry a base pair with no stock
            // for it to be a base OF.
            Row(name: "setBase", apply: { m, id in
                m.apply({ SidecarEdits.setBase($0, BaseSettings(mode: .measured,
                                                                ratios: BaseRatios(rg: 0.47, bg: 0.7),
                                                                measured: [14100, 30000, 21000])) },
                        to: id, actionName: "t")
            }, expectsDevelop: true, expectsExactDefaults: false, covers: "setBase",
               check: { develop, defaults in
                   // The whole default layer came with the pick, and ONLY the base moved.
                   XCTAssertEqual(develop.stock, defaults.stock, "setBase: the default stock came with it")
                   XCTAssertEqual(develop.tone, defaults.tone, "setBase: and the default tone")
                   XCTAssertEqual(develop.autoBalance, defaults.autoBalance, "setBase: and autoBalance")
                   XCTAssertEqual(develop.base.mode, .measured, "setBase: with the measured base on top")
                   XCTAssertNotNil(develop.base.ratios, "setBase: carrying the ratios")
               }),

            // The color axes, and the same question as the eyedropper asks: a grade on an
            // undeveloped frame has to arrive with the whole default layer under it, or the
            // file would carry a color grade with no stock for it to be a grade OF.
            Row(name: "setColourAxes", apply: { m, id in
                m.apply({ SidecarEdits.setColourAxes($0, ColourAxes(warm: 6, green: -3)) },
                        to: id, actionName: "t")
            }, expectsDevelop: true, expectsExactDefaults: false, covers: "setColourAxes",
               check: { develop, defaults in
                   XCTAssertEqual(develop.stock, defaults.stock, "setColourAxes: the default stock came with it")
                   XCTAssertEqual(develop.tone, defaults.tone, "setColourAxes: and the default tone")
                   XCTAssertEqual(develop.autoBalance, defaults.autoBalance, "setColourAxes: and autoBalance")
                   XCTAssertEqual(develop.base.mode, defaults.base.mode, "setColourAxes: the base did NOT move")
                   XCTAssertEqual(develop.colourAxes, ColourAxes(warm: 6, green: -3),
                                  "setColourAxes: with the grade on top")
               }),

            // The Tone row's values, the axes' question again: tone values on an undeveloped
            // frame arrive with the whole default layer under them.
            Row(name: "setToneAdjust", apply: { m, id in
                m.apply({ SidecarEdits.setToneAdjust($0, ToneAdjust(exposure: -0.1, contrast: 1.3,
                                                                    black: 0.15, white: 0.95)) },
                        to: id, actionName: "t")
            }, expectsDevelop: true, expectsExactDefaults: false, covers: "setToneAdjust",
               check: { develop, defaults in
                   XCTAssertEqual(develop.stock, defaults.stock, "setToneAdjust: the default stock came with it")
                   XCTAssertEqual(develop.tone, defaults.tone, "setToneAdjust: and the default tone")
                   XCTAssertEqual(develop.base.mode, defaults.base.mode, "setToneAdjust: the base did NOT move")
                   XCTAssertEqual(develop.toneAdjust, ToneAdjust(exposure: -0.1, contrast: 1.3, black: 0.15, white: 0.95),
                                  "setToneAdjust: with the values on top")
               }),

            // The Tone row's Stretch, the same question: a value on an undeveloped frame
            // arrives with the whole default layer under it.
            Row(name: "setStretch", apply: { m, id in
                m.apply({ SidecarEdits.setStretch($0, 0.5) }, to: id, actionName: "t")
            }, expectsDevelop: true, expectsExactDefaults: false, covers: "setStretch",
               check: { develop, defaults in
                   XCTAssertEqual(develop.stock, defaults.stock, "setStretch: the default stock came with it")
                   XCTAssertEqual(develop.tone, defaults.tone, "setStretch: and the default tone")
                   XCTAssertEqual(develop.base.mode, defaults.base.mode, "setStretch: the base did NOT move")
                   XCTAssertEqual(develop.stretch, 0.5, "setStretch: with the value on top")
               }),

            Row(name: "setGeometry", apply: { m, id in
                m.apply({ SidecarEdits.setGeometry($0, GeometrySettings(rotate: 90, flip: false,
                                                                        straightenDegrees: 0, crop: nil)) },
                        to: id, actionName: "t")
            // Geometry is the one layer that means the same thing on a negative as on a
            // positive, so a rotation writes geometry and leaves the frame a negative. Frames
            // stay negatives until they are developed, and a keypress saying "this one is
            // sideways" must not process a frame.
            }, expectsDevelop: false, writesGeometryOnly: true, covers: "setGeometry"),

            // The Metadata rows. Correcting what a frame was shot on is not a
            // decision about its positive, so like geometry it writes the capture block and
            // leaves a negative a negative.
            Row(name: "setCamera", apply: { m, id in
                m.apply({ SidecarEdits.setCamera($0, "Leica M6") }, to: id, actionName: "t")
            }, expectsDevelop: false, writesCaptureOnly: true, covers: "setCamera"),

            Row(name: "setFilm", apply: { m, id in
                m.apply({ SidecarEdits.setFilm($0, "Kodak Gold 200") }, to: id, actionName: "t")
            }, expectsDevelop: false, writesCaptureOnly: true, covers: "setFilm"),

            Row(name: "setTakenOn", apply: { m, id in
                m.apply({ SidecarEdits.setTakenOn($0, "2026-06-14") }, to: id, actionName: "t")
            }, expectsDevelop: false, writesCaptureOnly: true, covers: "setTakenOn"),

            Row(name: "resetEnhance on a frame with an enhance layer", apply: { m, id in
                // Seeded through the funnel first, so this row starts from a frame that has
                // something to reset. It asserts the develop layer SURVIVES a reset of the
                // neighboring layer.
                m.apply({ SidecarEdits.setEnhance($0, EnhanceSettings(contrast: 0.42)) }, to: id, actionName: "seed")
                m.apply({ SidecarEdits.resetEnhance($0) }, to: id, actionName: "t")
            }, expectsDevelop: true, covers: "resetEnhance"),

            // THE EXCEPTION. Reset Positive on a frame with no develop layer must stay a
            // no-op: seeding it would create the layer and the edit would clear it again,
            // so the frame would end where it started while a full sidecar write went to
            // disk. Asserted as zero saves below, not merely as a nil develop.
            Row(name: "resetDevelop on an undeveloped frame (the exception)", apply: { m, id in
                m.apply({ SidecarEdits.resetDevelop($0) }, to: id, actionName: "t")
            }, expectsDevelop: false, covers: "resetDevelop"),
        ]
    }

    @MainActor
    func testEveryMutatingEntryPointCommitsTheEffectiveDefaults() throws {
        for row in rows() {
            let (model, ids, roll) = try freshModel(count: 1)
            let id = ids[0]
            let frame = try XCTUnwrap(model.frame(id))
            let expected = try XCTUnwrap(model.renders.defaults.initial(for: frame.sidecar),
                                         "\(row.name): the defaults must resolve, or the row proves nothing")
            XCTAssertNil(frame.sidecar.develop, "\(row.name): this row starts undeveloped")

            // groupsByEvent is off in a test, so an explicit group is required around any
            // edit that registers undo.
            model.undoManager.beginUndoGrouping()
            row.apply(model, id)
            model.undoManager.endUndoGrouping()
            let after = try XCTUnwrap(model.frame(id))

            if row.expectsDevelop {
                let develop = try XCTUnwrap(after.sidecar.develop,
                                            "\(row.name): the funnel did not commit the defaults")
                if row.expectsExactDefaults {
                    XCTAssertEqual(develop, expected,
                                   "\(row.name): committed a develop layer that is not the effective defaults")
                } else {
                    row.check(develop, expected)
                }
                // The whole point: the file says what the picture does. Read the request off
                // the frame AFTER the edit, which is what the grid will draw next.
                XCTAssertEqual(model.renders.request(for: after)?.develop, develop,
                               "\(row.name): the committed value differs from the rendered one")
            } else if row.writesCaptureOnly {
                XCTAssertNil(after.sidecar.develop, "\(row.name): must leave the frame a negative")
                XCTAssertNotNil(after.sidecar.capture, "\(row.name): the capture block IS written")
                XCTAssertNil(model.renders.request(for: after),
                             "\(row.name): still a negative, so there is nothing to render")
                model.flushPendingSave(id)
                let onDisk = try XCTUnwrap(SidecarStore().load(for: after.url))
                XCTAssertNil(onDisk.sidecar.develop, "\(row.name): and the FILE says no develop layer")
                XCTAssertEqual(onDisk.sidecar.capture, after.sidecar.capture, "\(row.name): with the names in it")
            } else if row.writesGeometryOnly {
                XCTAssertNil(after.sidecar.develop, "\(row.name): must leave the frame a negative")
                XCTAssertEqual(after.sidecar.geometry?.rotate, 90, "\(row.name): the geometry IS written")
                XCTAssertNil(model.renders.request(for: after),
                             "\(row.name): still a negative, so there is nothing to render")
                model.flushPendingSave(id)
                let onDisk = try XCTUnwrap(SidecarStore().load(for: after.url))
                XCTAssertNil(onDisk.sidecar.develop, "\(row.name): and the FILE says no develop layer")
                XCTAssertEqual(onDisk.sidecar.geometry?.rotate, 90, "\(row.name): with the rotation in it")
            } else {
                XCTAssertNil(after.sidecar.develop, "\(row.name): must stay undeveloped")
                model.flushPendingSave(id)
                XCTAssertEqual(try sidecars(in: roll), [],
                               "\(row.name): a no-op edit must not write a sidecar at all")
            }
        }
    }

    /// The completeness half of the funnel: a new mutating entry point in `SidecarEdits` with
    /// no row above fails HERE rather than shipping with no coverage.
    ///
    /// Read from the source file rather than by reflection, because Swift has no reflection
    /// over static members. That is a real limitation and it is the right trade: the file is
    /// in this repo, the grep is exact (`public static func` at the top level of the enum),
    /// and a canary asserts the grep found the file and a plausible number of entry points,
    /// so a moved file reports a failure instead of a clean scan.
    func testEveryMutatingSidecarEditHasARow() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // FilmPositiveAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/FilmPositiveCore/Library/SidecarEdits.swift")
        let text = try XCTUnwrap(try? String(contentsOf: source, encoding: .utf8),
                                 "SidecarEdits.swift not found at \(source.path): this check cannot run")

        var found: Set<String> = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("public static func ") else { continue }
            let rest = t.dropFirst("public static func ".count)
            guard let paren = rest.firstIndex(of: "(") else { continue }
            found.insert(String(rest[rest.startIndex..<paren]))
        }

        // CANARY. A grep that finds nothing reports exactly what a fully covered file
        // reports, and the failure direction is toward PASS. Four is comfortably below the
        // six that exist today and above zero.
        XCTAssertGreaterThanOrEqual(found.count, 4,
                                    "the scan found \(found.count) entry points, so it is not reading the file")
        XCTAssertTrue(found.contains("setDevelop"), "canary: setDevelop must be found")

        let covered = Set(MainActor.assumeIsolated { rows() }.map(\.covers))
        let missing = found.subtracting(covered)
        XCTAssertTrue(missing.isEmpty,
                      "SidecarEdits entry points with no row in DefaultsCommitTests.rows(): "
                      + missing.sorted().joined(separator: ", ")
                      + ". Add a row asserting the defaults are committed, or state the exception.")
    }

    /// The selection funnel gets the rule too, as one undo step over every frame.
    @MainActor
    func testApplyToSelectionCommitsTheDefaultsOnEveryUndevelopedFrame() throws {
        let (model, ids, _) = try freshModel(count: 3)
        model.selection = Set(ids)
        model.applyToSelection({ SidecarEdits.setEnhance($0, EnhanceSettings(contrast: 0.42)) },
                               actionName: "Contrast")

        for id in ids {
            let f = try XCTUnwrap(model.frame(id))
            let develop = try XCTUnwrap(f.sidecar.develop, "every selected frame commits")
            XCTAssertEqual(develop.tone, ToneMode.none, "the default tone")
            XCTAssertEqual(f.sidecar.enhance?.contrast, 0.42)
        }
        // One undo step for the whole thing, which is what makes the commit invisible to
        // the user: Command Z takes the edit AND the committed layer back together.
        model.undoManager.undo()
        for id in ids {
            let f = try XCTUnwrap(model.frame(id))
            XCTAssertNil(f.sidecar.develop, "one Command Z undid the commit as well as the edit")
            XCTAssertNil(f.sidecar.enhance)
        }
    }

    /// `developSelection` commits exactly what was on screen, so pressing Positive does not
    /// change the picture. Every entry point runs this one function: the inspector header
    /// button, the toolbar button, Command D, the Positive menu item and the context menu.
    @MainActor
    func testPositiveCommitsTheValueAlreadyBeingRendered() throws {
        let (model, ids, _) = try freshModel(count: 2)
        model.selection = Set(ids)
        // An undeveloped frame has no render request, so what was "on screen" is what
        // the inspector's ROWS were showing, which is `effectiveDevelop`. That is the value
        // the press has to write, and it is the same one the frame renders through after.
        let before = try ids.map { id -> DevelopSettings in
            try XCTUnwrap(model.effectiveDevelop(for: try XCTUnwrap(model.frame(id))))
        }
        for id in ids {
            XCTAssertNil(model.renders.request(for: try XCTUnwrap(model.frame(id))),
                         "nothing renders before the press")
        }
        model.developSelection()
        for (i, id) in ids.enumerated() {
            let f = try XCTUnwrap(model.frame(id))
            XCTAssertEqual(f.sidecar.develop, before[i],
                           "Positive wrote something other than what the rows were showing")
            XCTAssertEqual(model.renders.request(for: f)?.develop, before[i],
                           "and the frame now renders through exactly that")
        }
    }

    // MARK: RIDER 3, write safety

    /// Reading every frame's render request writes NOTHING.
    @MainActor
    func testReadingEveryFramesRenderRequestSavesNothing() throws {
        let (model, ids, roll) = try freshModel(count: 8)
        model.selection = Set(ids)

        for id in ids {
            let f = try XCTUnwrap(model.frame(id))
            // Exactly what a grid cell and the closeup do on every SwiftUI pass, twice over
            // to catch a memo that writes on its second read.
            // No request for a negative. The read still has to write nothing, which is what
            // this test is about, and the inspector's read of the effective defaults is the
            // reader that remains.
            XCTAssertNil(model.renders.request(for: f), "a negative renders nothing")
            XCTAssertNil(model.renders.request(for: f, scale: .preview))
            XCTAssertNotNil(model.effectiveDevelop(for: f), "but the rows still read the defaults")
        }
        // And the inspector's whole read of the selection, which is the other reader of
        // effective develop.
        _ = model.selectionSummary

        let written = try sidecars(in: roll)
        XCTAssertEqual(written, [],
                       "rendering wrote \(written.count) sidecars: browsing a folder must write nothing")
        for id in ids {
            XCTAssertNil(model.frame(id)?.sidecar.develop, "and nothing was committed in memory either")
        }
    }

    /// The first Tone edit on an undeveloped frame saves exactly ONE sidecar, and that
    /// sidecar carries the tone the user chose AND the default stock and autoBalance
    /// beside it. A tone with no stock is a file that does not describe a
    /// picture.
    @MainActor
    func testAFirstToneEditSavesOneSidecarCarryingTheWholeDefaultLayer() throws {
        let (model, ids, roll) = try freshModel(count: 3)
        let target = ids[1]
        let frame = try XCTUnwrap(model.frame(target))
        let defaults = try XCTUnwrap(model.renders.defaults.initial(for: frame.sidecar))

        model.selection = [target]
        model.applyToSelection({ s in
            guard var d = s.develop else { return s }
            d.tone = .print
            return SidecarEdits.setDevelop(s, d)
        }, actionName: "Tone")

        model.flushPendingSave(target)

        XCTAssertEqual(try sidecars(in: roll), ["IMG_0002.xmp"],
                       "exactly one sidecar, for the one frame that was edited")
        // Read the BYTES that landed rather than the model's memory: the point of the test
        // is what the file says, and a defaults commit that only happened in memory would
        // pass every in-memory assertion.
        let onDisk = try XCTUnwrap(SidecarStore().load(for: roll.appendingPathComponent("IMG_0002.CR2")))
        let written = try XCTUnwrap(onDisk.sidecar.develop)
        XCTAssertEqual(written.tone, ToneMode.print, "the tone the user chose")
        XCTAssertEqual(written.stock, defaults.stock, "and the default stock beside it")
        XCTAssertEqual(written.autoBalance, defaults.autoBalance, "and the default autoBalance")
        XCTAssertEqual(written.base.mode, defaults.base.mode)

        for other in [ids[0], ids[2]] {
            XCTAssertNil(model.frame(other)?.sidecar.develop, "the unselected frames are untouched")
        }
    }

    // MARK: the geometry exception

    /// A geometry-only edit on a negative writes geometry and leaves the frame a negative.
    ///
    /// Frames stay negatives until they are developed, so seeding the develop layer on a
    /// rotation would process a frame on a keypress that said nothing except "this one is
    /// sideways". Geometry is the one layer
    /// that means the same thing on a negative as on a positive.
    @MainActor
    func testARotationOnANegativeWritesGeometryAndDoesNotProcessTheFrame() throws {
        let (model, ids, _) = try freshModel(count: 1)
        let id = ids[0]
        model.undoManager.beginUndoGrouping()
        model.apply({ SidecarEdits.setGeometry($0, GeometrySettings(rotate: 90)) }, to: id, actionName: "Rotate Right")
        model.undoManager.endUndoGrouping()

        let frame = try XCTUnwrap(model.frame(id))
        XCTAssertNil(frame.sidecar.develop, "a rotation is not a decision about the film")
        XCTAssertEqual(frame.sidecar.geometry?.rotate, 90, "and the rotation IS written")
        XCTAssertNil(model.renders.request(for: frame), "so it is still a negative")
    }

    /// The other side of the same rule, which is what stops the exception widening: a Tone
    /// edit on a negative still seeds the develop layer, because choosing a tone IS a
    /// decision about the positive.
    @MainActor
    func testAToneEditOnANegativeStillSeedsTheDefaults() throws {
        let (model, ids, _) = try freshModel(count: 1)
        let id = ids[0]
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            // The same shape every edit closure in the app has, and the reason the geometry
            // rule above must not call one twice.
            guard var d = s.develop else { return s }
            d.tone = .print
            return SidecarEdits.setDevelop(s, d)
        }, to: id, actionName: "Tone")
        model.undoManager.endUndoGrouping()

        let develop = try XCTUnwrap(model.frame(id)?.sidecar.develop, "a Tone edit commits the defaults")
        XCTAssertEqual(develop.tone, ToneMode.print)
    }

    /// A rotation and then a tone edit: the rotation does not process the frame, the tone
    /// does, and the geometry the rotation wrote survives the seeding.
    @MainActor
    func testGeometryWrittenOnANegativeSurvivesTheLaterCommit() throws {
        let (model, ids, _) = try freshModel(count: 1)
        let id = ids[0]
        model.undoManager.beginUndoGrouping()
        model.apply({ SidecarEdits.setGeometry($0, GeometrySettings(rotate: 180)) }, to: id, actionName: "Rotate")
        model.undoManager.endUndoGrouping()
        XCTAssertNil(model.frame(id)?.sidecar.develop)

        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            // The same shape every edit closure in the app has, and the reason the geometry
            // rule above must not call one twice.
            guard var d = s.develop else { return s }
            d.tone = .print
            return SidecarEdits.setDevelop(s, d)
        }, to: id, actionName: "Tone")
        model.undoManager.endUndoGrouping()

        let frame = try XCTUnwrap(model.frame(id))
        XCTAssertNotNil(frame.sidecar.develop)
        XCTAssertEqual(frame.sidecar.geometry?.rotate, 180, "the rotation was not thrown away")
    }

    // MARK: the Develop button (type PositiveButton)

    /// The label rule, which is pure so it has a test rather than a screenshot. The button
    /// never disappears, carries the count of UNprocessed frames only, and goes quiet rather
    /// than away when there is nothing left to do. Develop is what you do, a Positive is what
    /// you get.
    func testThePositiveButtonsLabelForZeroOneAndSeveralUnprocessedFrames() {
        XCTAssertEqual(PositiveButton.title(unprocessed: 0), "Positive")
        XCTAssertEqual(PositiveButton.title(unprocessed: 1), "Develop")
        XCTAssertEqual(PositiveButton.title(unprocessed: 3), "Develop (3)")
        // No count on one frame, because "Develop (1)" is a number nobody needs.
        XCTAssertFalse(PositiveButton.title(unprocessed: 1).contains("1"))
        // No label says "All positive", which reads wrong on a selection of one frame.
        for n in 0...4 {
            XCTAssertFalse(PositiveButton.title(unprocessed: n).lowercased().contains("all"))
        }
        XCTAssertEqual(PositiveButton.help(unprocessed: 0), "Every selected frame is already a positive")
        XCTAssertEqual(PositiveButton.help(unprocessed: 1), "Develop the selected frame.")
        XCTAssertEqual(PositiveButton.help(unprocessed: 3), "Develop the selected frames.")
    }

    /// A mixed selection: the press processes the negatives and leaves the frame that was
    /// already positive holding its OWN develop layer, not the defaults.
    ///
    /// That is what makes the button safe to press on a selection somebody has already
    /// worked on, and it is the claim `developSelection`'s `filter { !$0.isDeveloped }`
    /// makes without proving.
    @MainActor
    func testPressingPositiveOnAMixedSelectionLeavesTheDevelopedFrameAlone() throws {
        let (model, ids, _) = try freshModel(count: 3)
        // Frame 0 gets a develop layer of its own, deliberately unlike the defaults.
        model.selection = [ids[0]]
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            // The same shape every edit closure in the app has, and the reason the geometry
            // rule above must not call one twice.
            guard var d = s.develop else { return s }
            d.tone = .print
            return SidecarEdits.setDevelop(s, d)
        }, to: ids[0], actionName: "Tone")
        model.undoManager.endUndoGrouping()
        let mine = try XCTUnwrap(model.frame(ids[0])?.sidecar.develop)
        XCTAssertEqual(mine.tone, ToneMode.print)

        model.selection = Set(ids)
        XCTAssertEqual(model.selectionSummary.undevelopedCount, 2, "the count the button shows")
        XCTAssertEqual(PositiveButton.title(unprocessed: 2), "Develop (2)")
        model.developSelection()

        XCTAssertEqual(model.frame(ids[0])?.sidecar.develop, mine,
                       "the frame that was already positive keeps its own settings")
        for id in [ids[1], ids[2]] {
            let committed = try XCTUnwrap(model.frame(id)?.sidecar.develop)
            XCTAssertNotEqual(committed.tone, ToneMode.print, "the others got the defaults, not frame 0's tone")
        }
        XCTAssertEqual(model.selectionSummary.undevelopedCount, 0)
        XCTAssertEqual(PositiveButton.title(unprocessed: 0), "Positive")
    }
}

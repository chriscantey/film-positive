import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// One app-wide undo stack that reaches every edit, not just the sliders. Develop,
/// enhance, geometry, applying a look, both resets and removing a folder all undo and redo,
/// and at least a hundred steps are retained.
///
/// This is the criterion a screenshot can never settle, and it is also the one most likely
/// to rot: every new edit path is a chance to mutate a sidecar directly and silently leave
/// the stack behind. So the last test here walks the edit vocabulary itself.
final class UndoScopeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-undo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func modelWithFolder(_ name: String, count: Int = 3) throws -> (AppModel, URL) {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        // The app leaves `groupsByEvent` on, which closes one group per run loop event and
        // is what makes each user action one undo. A test has no event loop, so that outer
        // automatic group never closes and every explicit group nests inside it: the whole
        // test becomes a single undo. Turning it off here means the explicit groups in
        // `action` are the top level ones, which is the same shape the app produces.
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        return (model, dir)
    }

    /// One user action, in its own undo group.
    ///
    /// In the app each edit arrives on its own run loop event, and `UndoManager` with
    /// `groupsByEvent` closes a group per event, so every action is one undo. A test has no
    /// event loop, so without this every edit lands in ONE group and a single undo unwinds
    /// the whole test, which reads as "the wrong frame unwound" or "the folder came back
    /// without its edits". `modelWithFolder` turns the automatic grouping off so these
    /// explicit groups are the top level ones. The coalescer the inspector uses for a slider
    /// drag is this same pair of calls held open across a whole drag.
    @MainActor
    private func action(_ m: AppModel, _ body: () -> Void) {
        m.undoManager.beginUndoGrouping()
        body()
        m.undoManager.endUndoGrouping()
    }

    private func develop(_ stock: String = "kodak-gold-200") -> DevelopSettings {
        DevelopSettings(stock: stock, autoTone: true,
                        base: BaseSettings(mode: .anchor))
    }

    /// Every edit kind, one at a time: apply, undo back to where it started, redo forward.
    @MainActor
    func testEveryEditKindUndoesAndRedoes() throws {
        let (m, _) = try modelWithFolder("kinds")
        let id = try XCTUnwrap(m.framesInView.first?.id)

        var enhance = EnhanceSettings()
        enhance.contrast = 0.5
        var geometry = GeometrySettings()
        geometry.rotate = 90
        geometry.straightenDegrees = 1.25

        let edits: [(String, (Sidecar) -> Sidecar)] = [
            ("Develop", { SidecarEdits.setDevelop($0, self.develop()) }),
            ("Enhance", { SidecarEdits.setEnhance($0, enhance) }),
            ("Geometry", { SidecarEdits.setGeometry($0, geometry) }),
            ("Look", { SidecarEdits.applyLook($0, ShippedLooks.all[0]) }),
            // The Enhance Auto's write with its record.
            ("Auto Enhance", { SidecarEdits.applyAuto($0, enhance) }),
            // Its lit click, which keeps Levels and Curves.
            ("Clear Auto Enhance", SidecarEdits.clearAuto),
            ("Levels", { SidecarEdits.setLevels($0, Levels(inBlack: 0.05, gamma: 1.3)) }),
            ("Curves", { SidecarEdits.setCurves($0, Curves(red: CurvePoints(sanitising: [
                CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]))) }),
            // The Color Auto's write with its record, then its lit click.
            ("Auto Color", { SidecarEdits.applyColorAuto($0, WarmthTint(warmth: 0.12, tint: -0.04)) }),
            ("Clear Auto Color", SidecarEdits.clearColorAuto),
            // The eyedropper. It runs after Develop above, so the frame has a develop
            // layer for the base to live in by the time this case is reached.
            ("Pick Film Color", { SidecarEdits.setBase($0, BaseSettings(mode: .measured,
                                                                  ratios: BaseRatios(rg: 0.47, bg: 0.7),
                                                                  measured: [14100, 30000, 21000])) }),
            // The color axes, for the same reason as the eyedropper: they write into an
            // existing develop layer, so they run after Develop above.
            ("Colour Axes", { SidecarEdits.setColourAxes($0, ColourAxes(warm: 6, green: -3)) }),
            // The Tone row's Adjust, into the same existing develop layer.
            ("Tone Adjust", { SidecarEdits.setToneAdjust($0, ToneAdjust(exposure: -0.1, contrast: 1.3,
                                                                       black: 0.15, white: 0.95)) }),
            // The Tone row's Stretch, into the same existing develop layer.
            (StretchControl.actionName, { SidecarEdits.setStretch($0, 0.5) }),
            // The Metadata rows.
            ("Camera", { SidecarEdits.setCamera($0, "Leica M6") }),
            ("Film", { SidecarEdits.setFilm($0, "Kodak Gold 200") }),
            ("Date Taken", { SidecarEdits.setTakenOn($0, "2026-06-14") }),
            ("Reset Enhance", SidecarEdits.resetEnhance),
            ("Reset Develop", SidecarEdits.resetDevelop),
        ]

        for (name, edit) in edits {
            let before = try XCTUnwrap(m.frame(id)?.sidecar)
            action(m) { m.apply(edit, to: id, actionName: name) }
            let after = try XCTUnwrap(m.frame(id)?.sidecar)
            XCTAssertNotEqual(after, before, "\(name) changed nothing, so the test proves nothing")

            XCTAssertTrue(m.undoManager.canUndo, "\(name) registered no undo")
            m.undoManager.undo()
            XCTAssertEqual(m.frame(id)?.sidecar, before, "\(name) did not undo")

            XCTAssertTrue(m.undoManager.canRedo, "\(name) registered no redo")
            m.undoManager.redo()
            XCTAssertEqual(m.frame(id)?.sidecar, after, "\(name) did not redo")
        }
    }

    /// Removing a folder is an edit like any other, and it is the one that would hurt most
    /// to lose: the frames and their sidecar state come back with it.
    @MainActor
    func testRemovingAFolderUndoesWithItsFrames() throws {
        let (m, _) = try modelWithFolder("folder")
        let folderID = try XCTUnwrap(m.selectedFolderID)
        let frameID = try XCTUnwrap(m.framesInView.first?.id)
        action(m) { m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: frameID, actionName: "Develop") }
        let developed = try XCTUnwrap(m.frame(frameID)?.sidecar)

        action(m) { m.removeFolder(folderID) }
        XCTAssertTrue(m.folders.isEmpty)
        XCTAssertTrue(m.selection.isEmpty)

        m.undoManager.undo()
        XCTAssertEqual(m.folders.count, 1)
        XCTAssertEqual(m.frame(frameID)?.sidecar, developed, "the folder came back without its edits")

        m.undoManager.redo()
        XCTAssertTrue(m.folders.isEmpty, "removal did not redo")
    }

    /// One stack, app wide: edits to two different frames unwind in the order they were
    /// made, not per frame.
    @MainActor
    func testOneStackSpansFrames() throws {
        let (m, _) = try modelWithFolder("frames", count: 2)
        let a = try XCTUnwrap(m.framesInView.first?.id)
        let b = try XCTUnwrap(m.framesInView.last?.id)
        XCTAssertNotEqual(a, b)

        action(m) { m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: a, actionName: "Develop") }
        action(m) { m.apply({ SidecarEdits.setDevelop($0, self.develop("kodak-portra-400")) }, to: b, actionName: "Develop") }
        XCTAssertTrue(m.frame(a)!.isDeveloped)
        XCTAssertTrue(m.frame(b)!.isDeveloped)

        m.undoManager.undo()
        XCTAssertTrue(m.frame(a)!.isDeveloped, "the wrong frame unwound")
        XCTAssertFalse(m.frame(b)!.isDeveloped)
        m.undoManager.undo()
        XCTAssertFalse(m.frame(a)!.isDeveloped)
    }

    /// The depth: at least a hundred steps retained, and the whole run unwinds to the
    /// state it started from.
    @MainActor
    func testAtLeastAHundredStepsAreRetained() throws {
        let (m, _) = try modelWithFolder("depth")
        let id = try XCTUnwrap(m.framesInView.first?.id)
        let start = try XCTUnwrap(m.frame(id)?.sidecar)
        XCTAssertGreaterThanOrEqual(m.undoManager.levelsOfUndo, 100)

        // 120 distinct edits, each its own group, which is what 120 separate user actions
        // are. The view groups a whole drag deliberately; this is the floor underneath that.
        action(m) { m.apply({ SidecarEdits.setDevelop($0, self.develop()) }, to: id, actionName: "Develop") }
        for i in 1...119 {
            var enhance = EnhanceSettings()
            enhance.exposure = Double(i) / 200
            action(m) { m.apply({ SidecarEdits.setEnhance($0, enhance) }, to: id, actionName: "Exposure") }
        }
        XCTAssertEqual(m.frame(id)?.sidecar.enhance?.exposure, 119.0 / 200)

        var steps = 0
        while m.undoManager.canUndo, steps < 200 {
            m.undoManager.undo()
            steps += 1
        }
        XCTAssertGreaterThanOrEqual(steps, 120, "fewer than 120 steps were retained")
        XCTAssertEqual(m.frame(id)?.sidecar, start, "unwinding the whole stack did not reach the starting state")
    }

    /// The vocabulary itself: every transform `SidecarEdits` offers is reachable through
    /// `apply`, which is the only path that registers undo. A new edit added to the
    /// vocabulary and wired straight into a view would be a silent hole in the stack, so
    /// this counts them and fails when the count moves.
    @MainActor
    func testTheEditVocabularyIsCoveredByThisFile() throws {
        // resetDevelop, resetEnhance, setBase, setColourAxes, setDevelop, setEnhance,
        // applyLook, applyAuto, applyColorAuto, clearColorAuto, setGeometry, setCamera, setFilm
        let covered = ["applyAuto", "clearAuto", "setLevels", "setCurves", "applyColorAuto", "clearColorAuto", "resetDevelop", "resetEnhance", "setBase", "setColourAxes", "setDevelop",
                       "setEnhance", "applyLook", "setGeometry", "setCamera", "setFilm", "setTakenOn",
                       "setToneAdjust", "setStretch"]
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FilmPositiveCore/Library/SidecarEdits.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let declared = text.components(separatedBy: "public static func ").dropFirst()
            .map { String($0.prefix(while: { $0 != "(" })) }
            .sorted()
        XCTAssertEqual(declared.sorted(), covered.sorted(),
                       "the edit vocabulary moved: every transform needs a case in testEveryEditKindUndoesAndRedoes")
    }
}

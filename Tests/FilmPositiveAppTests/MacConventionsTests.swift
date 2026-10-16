import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Mac conventions audit. One test class per item would scatter a single piece of work
/// over eight files, so the items share this one, each under its own mark.
final class MacConventionsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-conv-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func makeRoll(_ name: String, count: Int = 3) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        return dir
    }

    @MainActor
    private func makeModel() -> AppModel {
        let m = AppModel(service: FailingRenderService(message: "no engine in this test"))
        // No event loop in a test, so the explicit groups below are the top level ones
        // (the same reasoning as UndoScopeTests).
        m.undoManager.groupsByEvent = false
        return m
    }

    // MARK: item 2, the Undo menu names its action

    @MainActor
    func testTheUndoTitleNamesTheLastEditAndTheRedoTitleFollowsAnUndo() throws {
        let m = makeModel()
        XCTAssertNotNil(m.addFolder(try makeRoll("undo")))
        m.undoManager.removeAllActions()
        m.undoTitles.refresh()
        XCTAssertEqual(m.undoTitles.undoTitle, "Undo", "an empty stack reads plain Undo")
        XCTAssertEqual(m.undoTitles.redoTitle, "Redo")

        let id = try XCTUnwrap(m.framesInView.first?.id)
        var g = GeometrySettings()
        g.straightenDegrees = 1.5
        m.undoManager.beginUndoGrouping()
        m.apply({ SidecarEdits.setGeometry($0, g) }, to: id, actionName: "Straighten")
        m.undoManager.endUndoGrouping()
        XCTAssertEqual(m.undoTitles.undoTitle, "Undo Straighten",
                       "the menu reads the name the edit registered, with no manual refresh")

        m.undoManager.undo()
        XCTAssertEqual(m.undoTitles.redoTitle, "Redo Straighten")
        XCTAssertEqual(m.undoTitles.undoTitle, "Undo", "and nothing is left to undo")
        m.undoManager.redo()
        XCTAssertEqual(m.undoTitles.undoTitle, "Undo Straighten")
    }

    /// The menu's own label must still carry a literal "Undo", or the ShortcutCatalog
    /// canary loses the command. This is the route half.
    func testCommandZInATextFieldUndoesTheTypingNotAFrameEdit() {
        XCTAssertEqual(FilmPositiveApp.undoRoute(textFieldHasFocus: true), .text)
        XCTAssertEqual(FilmPositiveApp.undoRoute(textFieldHasFocus: false), .model)
    }

    // MARK: item 3, reopen the last selected folder

    func testTheRememberedFolderWinsAndAMissingOneFallsBackToTheFirst() {
        let a = URL(fileURLWithPath: "/tmp/roll-a"), b = URL(fileURLWithPath: "/tmp/roll-b")
        XCTAssertEqual(AppModel.folderToReopen([a, b], remembered: b.path), b)
        XCTAssertEqual(AppModel.folderToReopen([a, b], remembered: "/tmp/roll-gone"), a)
        XCTAssertEqual(AppModel.folderToReopen([a, b], remembered: nil), a)
        XCTAssertNil(AppModel.folderToReopen([], remembered: b.path))
        // A trailing slash from a Finder drag is the same folder.
        XCTAssertEqual(AppModel.folderToReopen([a, URL(fileURLWithPath: "/tmp/roll-b/")], remembered: b.path)?.lastPathComponent, "roll-b")
    }

    @MainActor
    func testARelaunchReopensTheFolderThatWasSelected() throws {
        let first = try makeRoll("roll-first"), second = try makeRoll("roll-second")
        let m = makeModel()
        m.addFolder(first)
        m.addFolder(second)
        m.selectedFolderID = m.folders.first { $0.name == "roll-first" }?.id
        m.selectedFolderID = m.folders.first { $0.name == "roll-second" }?.id

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.folders.map(\.name), ["roll-first", "roll-second"], "canary: both came back")
        XCTAssertEqual(relaunched.selectedFolder?.name, "roll-second", "the selected roll, not the first in the list")

        relaunched.selectedFolderID = relaunched.folders.first?.id
        XCTAssertEqual(makeModel().selectedFolder?.name, "roll-first", "and a change is remembered too")
    }

    /// Anti: a remembered folder that did not come back does not get overwritten by the
    /// launch fallback, so it is still chosen once its volume returns.
    @MainActor
    func testTheLaunchFallbackDoesNotForgetTheRememberedFolder() throws {
        let m = makeModel()
        m.addFolder(try makeRoll("roll-here"))
        m.prefs.lastFolderPath = "/Volumes/Unplugged/roll-away"
        m.prefs.save()
        let relaunched = makeModel()
        XCTAssertEqual(relaunched.selectedFolder?.name, "roll-here")
        XCTAssertEqual(relaunched.prefs.lastFolderPath, "/Volumes/Unplugged/roll-away")
    }

    // MARK: item 4, Space toggles the grid and the closeup

    func testSpaceOpensFromTheGridAndClosesFromTheCloseup() {
        XCTAssertEqual(SpaceToggle.action(phase: .down, inCloseup: false, pickingBase: false), .open)
        XCTAssertEqual(SpaceToggle.action(phase: .down, inCloseup: true, pickingBase: false), .close)
    }

    /// Held Space repeats, and a toggle per repeat would flicker. One press, one toggle.
    func testARepeatIsSwallowedAndAReleaseIsNotOurs() {
        for closeup in [false, true] {
            XCTAssertEqual(SpaceToggle.action(phase: .repeat, inCloseup: closeup, pickingBase: false), .swallow)
            XCTAssertEqual(SpaceToggle.action(phase: .up, inCloseup: closeup, pickingBase: false), .notOurs)
        }
    }

    /// Anti: Space never cancels an armed eyedropper, which is Escape's first job. A toggle
    /// key that sometimes does something else is a trap.
    func testSpaceLeavesAnArmedEyedropperAlone() {
        XCTAssertEqual(SpaceToggle.action(phase: .down, inCloseup: true, pickingBase: true), .notOurs)
    }

    func testTheShortcutsPanelTeachesSpace() {
        XCTAssertTrue(ShortcutCatalog.groups.flatMap(\.rows).contains { $0.keys == "Space" })
    }

    // MARK: item 5, Command C copies All settings when no text field has the keyboard

    func testCommandCRoutesToSettingsOnlyOutsideATextFieldAndOnlyWithAFrame() {
        XCTAssertEqual(FilmPositiveApp.copyRoute(textFieldHasFocus: false, hasSourceFrame: true), .settings)
        XCTAssertEqual(FilmPositiveApp.copyRoute(textFieldHasFocus: true, hasSourceFrame: true), .text,
                       "a text field with the keyboard copies its text, always")
        XCTAssertEqual(FilmPositiveApp.copyRoute(textFieldHasFocus: false, hasSourceFrame: false), .text)
    }

    /// The copy reads the CURSOR frame when it is selected, and the pasteboard then carries
    /// every section, which is what the Command V paste route reads back.
    @MainActor
    func testCommandCCopiesEverySectionFromTheCursorFrame() throws {
        let m = makeModel()
        m.addFolder(try makeRoll("copy"))
        let ids = m.framesInView.map(\.id)
        var g = GeometrySettings()
        g.rotate = 90
        m.applyToFrames([ids[1]], { SidecarEdits.setGeometry($0, g) }, actionName: "Rotate Right")
        m.selection = Set(ids)
        m.cursor = ids[1]
        XCTAssertEqual(m.copySettingsSource?.id, ids[1], "the cursor frame, not the first selected")

        let pb = NSPasteboard(name: NSPasteboard.Name("fp-conv-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        m.copySettings(FrameSettingsSection.all, from: try XCTUnwrap(m.copySettingsSource).id, to: pb)
        XCTAssertTrue(FrameSettingsPasteboard.hasPayload(in: pb), "the paste route will find it")
    }

    // MARK: item 7, Rotate Left and Right on Command [ and Command ]

    func testAQuarterTurnWrapsBothWays() {
        XCTAssertEqual(AppModel.quarterTurned(0, by: -90), 270)
        XCTAssertEqual(AppModel.quarterTurned(270, by: 90), 0)
        XCTAssertEqual(AppModel.quarterTurned(90, by: 90), 180)
    }

    /// A grid selection turns together, as one undo named for what it did.
    @MainActor
    func testRotateActsOnTheWholeGridSelectionAsOneUndo() throws {
        let m = makeModel()
        m.addFolder(try makeRoll("rotate"))
        let ids = m.framesInView.map(\.id)
        m.undoManager.removeAllActions()
        m.selection = [ids[0], ids[2]]

        m.rotateSelection(clockwise: false)
        let turned = ids.map { m.frame($0)?.sidecar.geometry?.rotate ?? 0 }
        XCTAssertEqual(turned, [270, 0, 270], "the two selected frames turn, the other stays")
        XCTAssertEqual(m.undoTitles.undoTitle, "Undo Rotate Left")

        m.rotateSelection(clockwise: true)
        m.rotateSelection(clockwise: true)
        XCTAssertEqual(m.frame(ids[0])?.sidecar.geometry?.rotate, 90)

        m.undoManager.undo()
        m.undoManager.undo()
        m.undoManager.undo()
        XCTAssertEqual(ids.map { m.frame($0)?.sidecar.geometry?.rotate ?? 0 }, [0, 0, 0],
                       "three undos, three steps, every frame back")
    }

    /// In the closeup only the shown frame turns, however much is selected.
    @MainActor
    func testInTheCloseupOnlyTheShownFrameTurns() throws {
        let m = makeModel()
        m.addFolder(try makeRoll("rotate-closeup"))
        let ids = m.framesInView.map(\.id)
        m.selection = Set(ids)
        m.viewerFrameID = ids[1]
        m.rotateSelection(clockwise: true)
        XCTAssertEqual(ids.map { m.frame($0)?.sidecar.geometry?.rotate ?? 0 }, [0, 90, 0])
    }

    func testTheImageMenuIsInThePanelOnTheBracketKeys() {
        let row = ShortcutCatalog.groups.flatMap(\.rows).first { $0.menuCommands.contains("Rotate Left") }
        XCTAssertEqual(row?.keys, "⌘[  ⌘]")
    }

    // MARK: item 8, Move to Trash with the companions, undone rather than confirmed

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A model whose trasher moves into a scratch folder, never the real Trash.
    @MainActor
    private func trashingModel(_ roll: URL) throws -> (AppModel, URL) {
        let bin = scratch.appendingPathComponent("the-trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let m = makeModel()
        m.trashFile = { url in
            let to = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: to)
            return to
        }
        XCTAssertNotNil(m.addFolder(roll))
        m.undoManager.removeAllActions()
        return (m, bin)
    }

    @MainActor
    func testTrashTakesTheSidecarAndFprcAndUndoBringsEverythingBack() throws {
        let roll = try makeRoll("trash", count: 3)
        for f in ["IMG_0002.xmp", "IMG_0002.fprc", "IMG_0002.JPG"] {
            try Data([1, 2, 3]).write(to: roll.appendingPathComponent(f))
        }
        let before = names(roll)
        let (m, bin) = try trashingModel(roll)
        let ids = m.framesInView.map(\.id)
        m.selection = [ids[1]]
        m.cursor = ids[1]

        m.trashSelection()
        XCTAssertEqual(names(roll), ["IMG_0001.CR2", "IMG_0002.JPG", "IMG_0003.CR2"],
                       "the raw, its sidecar and its .fprc went, the camera JPEG stayed")
        XCTAssertEqual(names(bin).count, 3, "and all three are in the trash")
        XCTAssertEqual(m.framesInView.map(\.name), ["IMG_0001.CR2", "IMG_0003.CR2"])
        XCTAssertEqual(m.cursor?.lastPathComponent, "IMG_0003.CR2", "the cursor lands on the next frame")
        XCTAssertEqual(m.undoTitles.undoTitle, "Undo Move to Trash")
        XCTAssertNil(m.lastError)

        m.undoManager.undo()
        XCTAssertEqual(names(roll), before, "every file is home")
        XCTAssertEqual(names(bin), [], "and the trash is empty again")
        XCTAssertEqual(m.framesInView.map(\.name), ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"],
                       "in roll order")
        XCTAssertEqual(m.selection, [ids[1]], "and selected again")

        m.undoManager.redo()
        XCTAssertEqual(names(roll), ["IMG_0001.CR2", "IMG_0002.JPG", "IMG_0003.CR2"], "redo trashes it again")
        XCTAssertEqual(names(bin).count, 3)
    }

    /// A grid selection goes together, as one undo.
    @MainActor
    func testTrashingASelectionIsOneUndo() throws {
        let roll = try makeRoll("trash-many", count: 4)
        let (m, _) = try trashingModel(roll)
        let ids = m.framesInView.map(\.id)
        m.selection = [ids[0], ids[1], ids[3]]
        m.trashSelection()
        XCTAssertEqual(names(roll), ["IMG_0003.CR2"])
        XCTAssertEqual(m.cursor?.lastPathComponent, "IMG_0003.CR2")
        m.undoManager.undo()
        XCTAssertEqual(names(roll).count, 4, "one undo, all three back")
        XCTAssertFalse(m.undoManager.canUndo, "nothing else was on the stack")
    }

    /// In the closeup the shown frame goes and the closeup moves on to the next one, rather
    /// than dropping back to the grid.
    @MainActor
    func testTrashInTheCloseupMovesOnToTheNextFrame() throws {
        let roll = try makeRoll("trash-closeup", count: 3)
        let (m, _) = try trashingModel(roll)
        let ids = m.framesInView.map(\.id)
        m.selection = [ids[1]]
        m.viewerFrameID = ids[1]
        m.trashSelection()
        XCTAssertEqual(m.viewerFrameID?.lastPathComponent, "IMG_0003.CR2")
        // The last frame of the roll goes to the one before it.
        m.trashSelection()
        XCTAssertEqual(m.viewerFrameID?.lastPathComponent, "IMG_0001.CR2")
    }

    /// Anti: a sidecar shared with a raw that is staying refuses the whole trash, exactly as
    /// it refuses a move, and nothing leaves the folder.
    @MainActor
    func testASharedSidecarRefusesAndTouchesNothing() throws {
        let roll = try makeRoll("trash-shared", count: 1)
        try Data([1]).write(to: roll.appendingPathComponent("IMG_0001.DNG"))
        try Data([1]).write(to: roll.appendingPathComponent("IMG_0001.xmp"))
        let before = names(roll)
        let (m, bin) = try trashingModel(roll)
        let cr2 = try XCTUnwrap(m.framesInView.first { $0.name == "IMG_0001.CR2" }?.id)
        m.selection = [cr2]
        m.trashSelection()
        XCTAssertEqual(names(roll), before)
        XCTAssertEqual(names(bin), [])
        XCTAssertNotNil(m.lastError)
        XCTAssertFalse(m.undoManager.canUndo, "a refusal registers no undo")
    }

    /// Command Backspace in a text field is delete to start of line, never a trash.
    func testCommandBackspaceInATextFieldNeverTrashes() {
        XCTAssertEqual(FilmPositiveApp.trashRoute(textFieldHasFocus: true), .text)
        XCTAssertEqual(FilmPositiveApp.trashRoute(textFieldHasFocus: false), .frames)
        // The folder list holding the keyboard never trashes the grid's frames.
        XCTAssertEqual(FilmPositiveApp.trashRoute(textFieldHasFocus: false, sidebarHasKeyboard: true), .nothing)
        XCTAssertEqual(FilmPositiveApp.trashRoute(textFieldHasFocus: true, sidebarHasKeyboard: true), .text)
    }

    // MARK: next tier, View > Actual Size

    func testActualSizeIsOneImagePixelPerScreenPixelAndThenHasNothingToDo() {
        var z = CloseupZoom()
        z.update(layout: .init(viewport: CGSize(width: 800, height: 600),
                               imagePixels: CGSize(width: 6000, height: 4000), backingScale: 2))
        XCTAssertTrue(z.canShowActualSize, "at fit, a big frame is well under 100 percent")
        z.actualSize(around: nil)
        XCTAssertEqual(z.effectiveScale ?? 0, 1, accuracy: 0.0001)
        XCTAssertFalse(z.canShowActualSize, "and once there the item greys out")
    }

    /// Anti: a frame smaller than the window stays at fit rather than shrinking to 100 percent.
    func testASmallFrameStaysAtFit() {
        var z = CloseupZoom()
        z.update(layout: .init(viewport: CGSize(width: 800, height: 600),
                               imagePixels: CGSize(width: 400, height: 300), backingScale: 1))
        XCTAssertFalse(z.canShowActualSize)
        z.actualSize(around: nil)
        XCTAssertTrue(z.isFit)
    }

    // MARK: next tier, Page Up and Page Down in the grid

    func testPageDownAndUpMoveAScreenOfRowsAndStopAtTheEnds() {
        let order = Array(0..<50)
        typealias Nav = GridNavigation<Int>
        let at = { (i: Int) in Nav.State(selected: [i], anchor: i, cursor: i) }
        XCTAssertEqual(Nav.move(.pageDown(rows: 3), order: order, state: at(2), columns: 5)?.cursor, 17)
        XCTAssertEqual(Nav.move(.pageUp(rows: 3), order: order, state: at(17), columns: 5)?.cursor, 2)
        XCTAssertEqual(Nav.move(.pageDown(rows: 3), order: order, state: at(44), columns: 5)?.cursor, 49,
                       "past the end stops on the last frame")
        XCTAssertEqual(Nav.move(.pageUp(rows: 3), order: order, state: at(3), columns: 5)?.cursor, 0)
        XCTAssertNil(Nav.move(.pageUp(rows: 3), order: order, state: at(0), columns: 5),
                     "nothing to do at the top, so the key goes back to the system")
        XCTAssertEqual(Nav.move(.pageDown(rows: 0), order: order, state: at(0), columns: 5)?.cursor, 5,
                       "a grid that has not measured its rows yet still moves one row")
    }

    func testShiftPageDownExtendsTheSelection() {
        typealias Nav = GridNavigation<Int>
        let s = Nav.move(.pageDown(rows: 2), order: Array(0..<20), state: .init(selected: [0], anchor: 0, cursor: 0),
                         columns: 4, extend: true)
        XCTAssertEqual(s?.selected, Set(0...8))
    }

    // MARK: next tier, a refused drop says why

    @MainActor
    func testADropWithNoFileURLSaysWhyInTheBanner() {
        let m = makeModel()
        XCTAssertNil(m.notice)
        m.addDropped([NSItemProvider(object: "a picture from a photo library" as NSString)])
        XCTAssertEqual(m.notice, AppModel.refusedDropNotice)
        XCTAssertTrue(m.notice?.contains("Finder") == true)
    }
}

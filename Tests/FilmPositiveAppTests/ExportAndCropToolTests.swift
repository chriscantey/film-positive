import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The parts of the Export sheet and the closeup's crop overlay that are decisions rather
/// than pixels: which frames the sheet will write, where they go by default, and when the
/// crop rectangle may be raised at all.
///
/// The export loop itself is not here. It lives in Core as `BatchExport.run` and is tested
/// there, against a render service and the memory ceiling it has to hold. What IS testable
/// in the app target is the selection-to-targets rule, which is where a silent bug would
/// live: a sheet that reports "4 frames" and writes 3, or one that skips nothing and then
/// fails halfway through on an undeveloped frame.
final class ExportAndCropToolTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func modelWithFolder(count: Int = 4) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    @MainActor
    private func develop(_ model: AppModel, _ ids: [Frame.ID], stock: String = "kodak-gold-200") {
        for id in ids {
            model.undoManager.beginUndoGrouping()
            model.apply({ s in
                SidecarEdits.setDevelop(s, DevelopSettings(
                    stock: stock,
                    autoTone: false,
                    base: BaseSettings(mode: .anchor, anchor: 4000, ratios: BaseRatios(rg: 0.22648, bg: 1.32673))))
            }, to: id, actionName: "seed")
            model.undoManager.endUndoGrouping()
        }
    }

    // MARK: which frames get written

    /// Undeveloped frames are skipped rather than failed on, and the count the sheet shows
    /// is the count it will write. Written so it would fail against a version that returned
    /// one target per selected frame: the selection here is four and the answer is two.
    @MainActor
    func testExportTargetsAreTheDevelopedFramesOfTheSelection() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, [ids[0], ids[2]])
        model.selection = Set(ids)

        let targets = model.exportTargets
        XCTAssertEqual(targets.count, 2, "an undeveloped frame has nothing to export")
        XCTAssertEqual(model.selection.count, 4, "and the selection itself is untouched")
        // Folder order, not selection-set order, so the progress counter counts in the order
        // the user sees. A Set has no order, so this is the assertion that catches it.
        XCTAssertEqual(targets.map(\.stem), ["IMG_0001", "IMG_0003"])
        for t in targets {
            XCTAssertEqual(t.develop.stock, "kodak-gold-200")
            XCTAssertEqual(t.url.pathExtension, "CR2")
            XCTAssertNil(t.lookID, "no look was set, so none is carried")
        }
    }

    /// An empty selection and a wholly undeveloped selection both produce nothing, and
    /// neither is an error. The sheet's "nothing to export" state depends on this being an
    /// empty list rather than a throw.
    @MainActor
    func testExportTargetsIsEmptyWithNothingDeveloped() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = []
        XCTAssertTrue(model.exportTargets.isEmpty)
        model.selection = Set(ids)
        XCTAssertTrue(model.exportTargets.isEmpty, "nothing in this folder is developed yet")
    }

    /// Geometry, enhance and look travel with the target as VALUES. The export runs off the
    /// main actor while the user keeps editing, so a target that read its frame later would
    /// export a state nobody asked for.
    @MainActor
    func testATargetIsASnapshotNotALiveReference() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, [ids[0]])
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            var e = s.enhance ?? .identity
            e.contrast = 0.5
            return SidecarEdits.setEnhance(s, e)
        }, to: ids[0], actionName: "seed enhance")
        model.undoManager.endUndoGrouping()
        model.selection = [ids[0]]

        let before = try XCTUnwrap(model.exportTargets.first)
        XCTAssertEqual(before.enhance.contrast, 0.5)

        // Edit the frame after taking the target. The captured value must not move.
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            var e = s.enhance ?? .identity
            e.contrast = -0.9
            return SidecarEdits.setEnhance(s, e)
        }, to: ids[0], actionName: "later edit")
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(before.enhance.contrast, 0.5, "the snapshot followed the live sidecar")
        XCTAssertEqual(model.exportTargets.first?.enhance.contrast, -0.9, "a fresh read sees the edit")
    }

    // MARK: where they go

    /// With no remembered folder, exports land in a Positives folder beside the raws rather
    /// than in the raw folder itself, so a re-import never picks up the positives.
    @MainActor
    func testDefaultExportFolderSitsBesideTheRawsWhenNothingIsRemembered() throws {
        let (model, _) = try modelWithFolder()
        let folder = try XCTUnwrap(model.defaultExportFolder)
        XCTAssertEqual(folder.lastPathComponent, "Positives")
        // Compared as paths, not as URLs. The folder is built with isDirectory: true, so
        // deletingLastPathComponent leaves a trailing slash that standardizedFileURL does
        // not remove, and two URLs naming the same directory compare unequal.
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL.path,
                       try XCTUnwrap(model.selectedFolder?.url).standardizedFileURL.path)
    }

    /// Mode 2. The folder named in Settings wins from every working folder, and one that
    /// has since been deleted does NOT: it falls back rather than creating a stub
    /// directory inside the empty mount point of a drive that is not plugged in.
    @MainActor
    func testAlwaysThisFolderWinsOnlyWhileItStillExists() throws {
        let (model, _) = try modelWithFolder()
        let chosen = scratch.appendingPathComponent("somewhere-else", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        model.prefs.exportFolder = chosen.path
        model.prefs.exportDestination = .fixedFolder
        // Paths again: URL(fileURLWithPath:) decides the trailing slash by probing the disk,
        // so comparing URLs here would pass or fail on whether the directory exists yet.
        XCTAssertEqual(model.defaultExportFolder?.standardizedFileURL.path, chosen.standardizedFileURL.path)

        try FileManager.default.removeItem(at: chosen)
        XCTAssertEqual(model.defaultExportFolder?.lastPathComponent, "Positives",
                       "a folder that is gone has to fall back, not be handed to the exporter")
    }

    /// The migration, and it is the whole reason the mode is a separate field. A preferences
    /// file with no mode can carry a saved `exportFolder` the user never chose as a fixed
    /// destination. Reading that as a deliberate "always this folder" would be wrong, so an
    /// absent mode means Positives-in-folder and the saved path sits there unused until they
    /// choose the second mode.
    @MainActor
    func testASavedFolderFromAnOlderBuildDoesNotSilentlyBecomeAlwaysThisFolder() throws {
        let (model, _) = try modelWithFolder()
        let chosen = scratch.appendingPathComponent("old-habit", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        // Round-tripped rather than assigned, because that reproduces a file with no mode
        // exactly: the mode is nil, so the encoder omits the key entirely and the decoder
        // has to supply the default. Written this way rather than as literal JSON so it
        // does not have to be edited every time a preference is added.
        var older = Preferences()
        older.exportFolder = chosen.path
        let blob = try JSONEncoder().encode(older)
        XCTAssertFalse(try XCTUnwrap(String(data: blob, encoding: .utf8)).contains("exportDestinationMode"),
                       "the old file genuinely has no mode key in it")
        model.prefs = try JSONDecoder().decode(Preferences.self, from: blob)
        XCTAssertEqual(model.prefs.exportFolder, chosen.path, "the old file decoded")
        XCTAssertNil(model.prefs.exportDestinationMode, "the older file has no mode in it")
        XCTAssertEqual(model.prefs.exportDestination, .positivesInFolder)
        XCTAssertEqual(model.defaultExportFolder?.lastPathComponent, "Positives",
                       "a path that was never a choice must not act like one")

        // And it is kept, so choosing the second mode arrives pre-filled.
        model.prefs.exportDestination = .fixedFolder
        XCTAssertEqual(model.defaultExportFolder?.standardizedFileURL.path, chosen.standardizedFileURL.path)
    }

    /// Two ways mode 2 can be half-set, and neither may hand the exporter a dead path.
    /// A word from a newer build degrades to mode 1 rather than refusing to decode, and
    /// choosing "Always this folder" without choosing a folder still exports somewhere.
    @MainActor
    func testAHalfSetSecondModeStillLandsSomewhereReal() throws {
        let (model, _) = try modelWithFolder()

        model.prefs.exportDestinationMode = "someFutureIdeaWeDoNotHaveYet"
        XCTAssertEqual(model.prefs.exportDestination, .positivesInFolder,
                       "an unknown word costs the mode, never the whole preferences file")
        XCTAssertEqual(model.defaultExportFolder?.lastPathComponent, "Positives")

        model.prefs.exportDestination = .fixedFolder
        model.prefs.exportFolder = nil
        XCTAssertEqual(model.defaultExportFolder?.lastPathComponent, "Positives",
                       "the second mode with no folder in it falls through, it does not fail")
    }

    /// The session override beats both modes, and it beats them from every folder: it holds
    /// within one open session, not within one folder.
    @MainActor
    func testASessionPickBeatsBothModesAndSurvivesSwitchingFolders() throws {
        let (model, _) = try modelWithFolder()
        let picked = scratch.appendingPathComponent("picked-in-the-sheet", isDirectory: true)
        let named = scratch.appendingPathComponent("named-in-settings", isDirectory: true)
        for d in [picked, named] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        model.prefs.exportFolder = named.path
        model.prefs.exportDestination = .fixedFolder
        model.sessionExportFolder = picked

        XCTAssertEqual(model.defaultExportFolder?.standardizedFileURL.path, picked.standardizedFileURL.path,
                       "the pick beats the setting")

        // A second roll, opened in the same run of the app.
        let other = scratch.appendingPathComponent("another-roll", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: other.appendingPathComponent("IMG_9001.CR2"))
        XCTAssertNotNil(model.addFolder(other))
        XCTAssertEqual(model.defaultExportFolder?.standardizedFileURL.path, picked.standardizedFileURL.path,
                       "the pick holds across a folder change, and dies with the process instead")
    }

    /// Nothing about the sheet's pick reaches disk. Probed over the encoded preferences
    /// rather than over the field list, so it stays true if somebody adds a field later.
    @MainActor
    func testThePreferencesFileCarriesNoRecordOfASessionPick() throws {
        let (model, _) = try modelWithFolder()
        let picked = scratch.appendingPathComponent("picked-in-the-sheet-2", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        model.sessionExportFolder = picked

        let blob = try JSONEncoder().encode(model.prefs)
        let text = try XCTUnwrap(String(data: blob, encoding: .utf8))
        XCTAssertFalse(text.contains("picked-in-the-sheet-2"),
                       "a folder picked in the sheet must not be encodable into preferences at all")
    }

    /// Mode 1 answers with a folder that does not exist yet, on purpose: asking where
    /// exports go must not create anything, and `ExportSheet.start` makes it at export
    /// time. Only the first half is provable here, because the creation lives in the
    /// sheet; the creating line itself is checked by reading it.
    @MainActor
    func testAskingWhereExportsGoCreatesNothing() throws {
        let (model, _) = try modelWithFolder()
        let target = try XCTUnwrap(model.defaultExportFolder)
        XCTAssertEqual(target.lastPathComponent, "Positives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "the answer is a destination, not a side effect")
    }

    // MARK: the closeup's crop overlay

    /// The rectangle needs something positive to draw over. Raising it on an undeveloped
    /// frame would put a crop box over the negative, which is a different picture from the
    /// one the crop will apply to.
    @MainActor
    func testTheCropOverlayRefusesToOpenWithNothingDeveloped() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = [ids[0]]
        model.cursor = ids[0]
        model.toggleCropOverlay()
        XCTAssertFalse(model.showsCropOverlay, "no positive frame to crop")
        XCTAssertNil(model.viewerFrameID, "and the closeup did not open either")
        XCTAssertFalse(model.canToggleCropOverlay)

        develop(model, [ids[0]])
        XCTAssertTrue(model.canToggleCropOverlay)
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay)
        XCTAssertEqual(model.viewerFrameID, ids[0], "Command K from the grid opens the closeup on the cursor")
    }

    /// In the closeup the rectangle is drawn over the frame on screen, and the drag writes
    /// that frame's geometry alone, because a crop rectangle is per frame. It is not a
    /// selection event: the other selected frames are still selected, which is what keeps
    /// Reset Crop, the sliders and the rest of the inspector acting on all of them.
    /// `SelectionThroughCloseupTests` holds the rest of that rule.
    @MainActor
    func testTheOverlayDrawsOnTheFrameOnScreenWithoutNarrowingTheSelection() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, ids)
        model.selection = Set(ids)
        model.viewerFrameID = ids[2]
        model.cursor = ids[2]
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay)
        XCTAssertEqual(model.selection, Set(ids), "the wider selection came through untouched")
        XCTAssertEqual(model.viewerFrameID, ids[2], "and the rectangle is over the frame on screen")
        XCTAssertEqual(model.cursor, ids[2])
    }

    /// The rectangle survives the arrows, which is the whole flow it exists for: stay in
    /// crop mode and adjust each frame of the roll as it comes up.
    @MainActor
    func testTheOverlayStaysOnWhileTheArrowsWalkTheRoll() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, ids)
        model.selection = [ids[0]]
        model.cursor = ids[0]
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay)

        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[1], "the closeup moved with the arrow")
        XCTAssertTrue(model.showsCropOverlay, "and the rectangle came with it")
    }

    /// Done leaves the rectangle behind. It is a mode of the closeup, so the next frame
    /// opened from the grid shows the picture rather than landing in a crop nobody asked for.
    @MainActor
    func testDoneClosesTheCloseupAndTheOverlayTogether() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, [ids[0]])
        model.selection = [ids[0]]
        model.cursor = ids[0]
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay)

        model.closeViewer()
        XCTAssertNil(model.viewerFrameID)
        XCTAssertFalse(model.showsCropOverlay)
    }

    /// Nothing detects on its own. Raising the rectangle on a frame with no crop of its
    /// own leaves it uncropped, with the box at the frame's edges, until the user presses
    /// Detect in the bar or runs Detect Crop over a selection from the grid.
    ///
    /// This asserts the state the closeup builds its editor from. The other half, that the
    /// closeup's load path contains no detector call at all, is a grep: `AutoCrop.detect`
    /// appears exactly once in ViewerView.swift, inside `detection(on:)`, which only the
    /// Detect button and a detection it left pending ever reach.
    @MainActor
    func testRaisingTheRectangleDoesNotCropAnything() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, [ids[0]])
        model.selection = [ids[0]]
        model.cursor = ids[0]
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay)

        let frame = try XCTUnwrap(model.frame(ids[0]))
        XCTAssertNil(frame.sidecar.geometry?.crop, "the sidecar gained no crop")
        let editor = CropEditor(geometry: frame.sidecar.geometry ?? GeometrySettings(), originalAspect: 1.5)
        XCTAssertFalse(editor.hasCrop, "and the editor the closeup builds from it holds none")
    }

    /// Toggling is idempotent: two presses of Command K put everything back, including the
    /// refusal, which leaves the rectangle down rather than flipping a flag the open path
    /// would have refused to set.
    @MainActor
    func testTheToggleIsIdempotentAndRespectsTheSameGate() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = [ids[0]]
        model.cursor = ids[0]
        model.toggleCropOverlay()
        XCTAssertFalse(model.showsCropOverlay)
        model.toggleCropOverlay()
        XCTAssertFalse(model.showsCropOverlay, "a refusal twice is still a refusal")

        develop(model, [ids[0]])
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay)
        model.toggleCropOverlay()
        XCTAssertFalse(model.showsCropOverlay)
        XCTAssertEqual(model.viewerFrameID, ids[0], "hiding the rectangle does not leave the closeup")
        model.toggleCropOverlay()
        XCTAssertTrue(model.showsCropOverlay, "and it comes back on the frame on screen")
    }

    /// The angle readout beside the straighten slider. It exists as a function taking a
    /// `Double` so the negligible case cannot be written as a bare `0` inside the
    /// `String(format:)` call, where it stays a `Swift.Int` against a `%.2f` and makes
    /// Foundation log a fault on every layout of the bar.
    ///
    /// These assertions pin the strings, not the fault: an Int passed through varargs
    /// happens to print the same "0.00" here, so the real check is the one that cannot be
    /// written as a unit test, a zero fault count in the app's log across open, Command K,
    /// Reset and Flip. What the signature buys is that the bug cannot come back by accident.
    func testTheAngleReadoutFormatsADouble() {
        XCTAssertEqual(CropControlBar.degreesText(0), "0.00\u{00B0}")
        XCTAssertEqual(CropControlBar.degreesText(-0.0004), "0.00\u{00B0}", "a negligible angle reads as flat zero")
        XCTAssertEqual(CropControlBar.degreesText(-1.25), "-1.25\u{00B0}")
        XCTAssertEqual(CropControlBar.degreesText(3.5), "3.50\u{00B0}")
    }
}

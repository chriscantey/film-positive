import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Every reset is selection-wide at the model level, and `ReportedDefectTests` proves that. A
/// multi-selection is lost BEFORE the click if the closeup rewrites `selection` to a single
/// frame on the way past. These tests guard the selection through the closeup, site by site.
///
/// The rule in one line: the closeup shows ONE frame and the selection is whatever it was.
final class SelectionThroughCloseupTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-collapse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: site 1, openViewer (GridActions.swift), KEEPS

    @MainActor
    func testOpeningTheCloseupOnASelectedFrameKeepsAllThree() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = Set(ids)
        model.cursor = ids[1]

        model.openViewer()

        XCTAssertEqual(model.selection, Set(ids), "the closeup shows one frame, it does not select one")
        XCTAssertEqual(model.viewerFrameID, ids[1], "and the frame on screen is the one it opened on")
        XCTAssertEqual(model.cursor, ids[1])
    }

    /// A double click on a cell that is NOT in the selection means that frame, the way a
    /// plain click on it would. This is the path the grid's double click takes.
    @MainActor
    func testOpeningTheCloseupOnAnUnselectedFrameSelectsThatFrameAlone() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = [ids[0], ids[1]]
        model.anchor = ids[0]

        model.openViewer(on: ids[2])

        XCTAssertEqual(model.selection, [ids[2]], "outside the selection, it is an ordinary click")
        XCTAssertEqual(model.viewerFrameID, ids[2])
        XCTAssertEqual(model.anchor, ids[2], "and a shift extend afterwards ranges from it")
    }

    /// The same double click INSIDE the selection keeps every frame.
    @MainActor
    func testADoubleClickInsideTheSelectionKeepsEveryFrame() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = Set(ids)
        model.anchor = ids[0]

        model.openViewer(on: ids[2])

        XCTAssertEqual(model.selection, Set(ids))
        XCTAssertEqual(model.viewerFrameID, ids[2])
        XCTAssertEqual(model.anchor, ids[0], "an open inside the selection is not a click, so the anchor stays")
    }

    @MainActor
    func testToggleViewerKeepsTheSameWayBecauseItIsTheSameCall() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = Set(ids)
        model.cursor = ids[0]

        model.toggleViewer()

        XCTAssertEqual(model.selection, Set(ids))
    }

    /// Done and Escape are not selection events. The three frames that went into the
    /// closeup are the three frames that come back out of it.
    @MainActor
    func testClosingTheCloseupLeavesTheSelectionExactlyAsItWas() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = Set(ids)
        model.cursor = ids[2]
        model.openViewer()

        model.closeViewer()

        XCTAssertNil(model.viewerFrameID)
        XCTAssertEqual(model.selection, Set(ids), "still three frames, back in the grid")
        XCTAssertEqual(model.cursor, ids[2], "on the frame that was on screen")
    }

    /// In the closeup Reset Positive reaches the SHOWN frame alone. The other two stay
    /// positive, and the selection is still three, because the walk and the header read it.
    @MainActor
    func testResetPositiveInTheCloseupReachesTheShownFrameOnly() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.selection = Set(ids)
        model.cursor = ids[0]

        model.openViewer()
        XCTAssertEqual(model.viewerFrameID, ids[0])
        model.resetDevelopSelection()

        XCTAssertNil(model.frame(ids[0])!.sidecar.develop, "the shown frame is reset")
        XCTAssertNotNil(model.frame(ids[1])!.sidecar.develop, "a selected frame off screen is untouched")
        XCTAssertNotNil(model.frame(ids[2])!.sidecar.develop, "a selected frame off screen is untouched")
        XCTAssertEqual(model.selection, Set(ids), "the selection survives for the walk and the header")
    }

    /// The arrows move the shown frame, and the reset follows it: the frame on screen is the
    /// one it reaches, whichever of the three that is.
    @MainActor
    func testAfterAnArrowTheResetReachesTheNewlyShownFrame() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.selection = Set(ids)
        model.cursor = ids[0]
        model.openViewer()

        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[1])
        model.resetDevelopSelection()

        XCTAssertNotNil(model.frame(ids[0])!.sidecar.develop)
        XCTAssertNil(model.frame(ids[1])!.sidecar.develop, "the frame now on screen is reset")
        XCTAssertNotNil(model.frame(ids[2])!.sidecar.develop)
    }

    /// Back in the grid nothing changed: the same reset over the same three reaches all
    /// three again once the closeup is closed.
    @MainActor
    func testBackInTheGridTheResetReachesAllThreeAgain() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.selection = Set(ids)
        model.cursor = ids[0]
        model.openViewer()
        model.closeViewer()

        model.resetDevelopSelection()

        for id in ids { XCTAssertNil(model.frame(id)!.sidecar.develop, "every selected frame is reset") }
    }

    /// The control: same three frames, same reset, no closeup in between.
    @MainActor
    func testTheSameResetWithoutTheCloseupReachesAllThree() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.selection = Set(ids)

        model.resetDevelopSelection()

        for id in ids { XCTAssertNil(model.frame(id)!.sidecar.develop) }
    }

    // MARK: the arrows walk the selection, and never change it

    @MainActor
    func testArrowsInTheCloseupWalkTheSelectedFramesOnly() throws {
        let (model, ids) = try modelWithFolder(count: 5)
        model.selection = [ids[0], ids[2], ids[4]]
        model.cursor = ids[0]
        model.openViewer()

        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[2], "it skipped the frame that is not selected")
        XCTAssertEqual(model.selection, [ids[0], ids[2], ids[4]], "and selected nothing new")

        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[4])
        XCTAssertFalse(model.navigate(.right, columns: 1), "the last selected frame is the end of the walk")
        XCTAssertEqual(model.selection, [ids[0], ids[2], ids[4]])

        XCTAssertTrue(model.navigate(.left, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[2], "and it walks back the same way")
        XCTAssertEqual(model.selection, [ids[0], ids[2], ids[4]])
    }

    /// Home and End are the ends of the WALK, which is the selection here, not the roll.
    @MainActor
    func testHomeAndEndInTheCloseupJumpToTheEndsOfTheSelection() throws {
        let (model, ids) = try modelWithFolder(count: 5)
        model.selection = [ids[1], ids[3]]
        model.cursor = ids[1]
        model.openViewer()

        XCTAssertTrue(model.navigate(.last, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[3])
        XCTAssertTrue(model.navigate(.first, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[1])
        XCTAssertEqual(model.selection, [ids[1], ids[3]])
    }

    /// With exactly one frame selected the closeup is a gallery over the whole roll.
    @MainActor
    func testArrowsWalkTheWholeRollWhenOneFrameIsSelected() throws {
        let (model, ids) = try modelWithFolder(count: 4)
        model.selectByClick(ids[1], modifiers: [])
        model.openViewer()

        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[2], "the next frame in the folder, selected or not")
        XCTAssertEqual(model.selection, [ids[2]], "and the selection follows the cursor, as in the grid")
    }

    /// The grid is unaffected: an arrow there moves a multi-selection, because the walk is
    /// gated on the closeup being up.
    @MainActor
    func testArrowsInTheGridStillMoveTheSelectionAsBefore() throws {
        let (model, ids) = try modelWithFolder(count: 4)
        model.selection = Set(ids)
        model.cursor = ids[0]

        XCTAssertTrue(model.navigate(.right, columns: 4))

        XCTAssertEqual(model.selection, [ids[1]], "an arrow in the grid is still a move, not a walk")
        XCTAssertNil(model.viewerFrameID)
    }

    // MARK: the header text

    @MainActor
    func testTheHeaderNamesBothNumbersWithSeveralFramesSelected() throws {
        let (model, ids) = try modelWithFolder(count: 5)
        model.selection = [ids[0], ids[2], ids[4]]
        model.cursor = ids[0]
        model.openViewer()

        XCTAssertEqual(model.closeupPosition, "3 selected, showing 1 of 3")
        model.navigate(.right, columns: 1)
        XCTAssertEqual(model.closeupPosition, "3 selected, showing 2 of 3")
    }

    @MainActor
    func testTheHeaderIsThePositionInTheRollWithOneFrameSelected() throws {
        let (model, ids) = try modelWithFolder(count: 5)
        model.selectByClick(ids[3], modifiers: [])
        model.openViewer()

        XCTAssertEqual(model.closeupPosition, "4 of 5")
    }

    @MainActor
    func testTheHeaderIsEmptyOutsideTheCloseup() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = Set(ids)

        XCTAssertEqual(model.closeupPosition, "", "the grid has its own subtitle")
    }

    // MARK: site 2, toggleCropOverlay (AppModel.swift), KEEPS

    /// From the GRID, Command K opens the closeup on its entry frame with the rectangle up
    /// and leaves the selection alone, so a crop pass that starts from three selected
    /// frames still has three selected when it gets there.
    @MainActor
    func testTurningTheCropOverlayOnFromTheGridKeepsTheSelection() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.selection = Set(ids)
        model.cursor = ids[1]

        model.toggleCropOverlay()

        XCTAssertTrue(model.showsCropOverlay)
        XCTAssertEqual(model.viewerFrameID, ids[1])
        XCTAssertEqual(model.selection, Set(ids))
        XCTAssertEqual(model.closeupPosition, "3 selected, showing 2 of 3",
                       "and the header says what Reset Crop is about to reach")
    }

    /// From INSIDE the closeup it keeps the selection too. The rectangle edits the frame on
    /// screen, which is a fact about what the drag writes, not a reason to drop the rest.
    @MainActor
    func testTurningTheCropOverlayOnInsideTheCloseupKeepsTheSelection() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.cursor = ids[0]
        model.openViewer()
        model.selection = Set(ids)          // widened by hand while the closeup is up

        model.toggleCropOverlay()

        XCTAssertTrue(model.showsCropOverlay)
        XCTAssertEqual(model.selection, Set(ids))
        XCTAssertEqual(model.viewerFrameID, ids[0], "still showing the frame it was showing")
    }

    /// Reset Crop from the closeup with three selected clears the SHOWN frame's geometry
    /// alone, the one frame the rectangle edits.
    @MainActor
    func testResetCropInTheCloseupReachesTheShownFrameOnly() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        for id in ids {
            model.undoManager.beginUndoGrouping()
            model.apply({ SidecarEdits.setGeometry($0, GeometrySettings(rotate: 90)) }, to: id, actionName: "seed turn")
            model.undoManager.endUndoGrouping()
        }
        model.selection = Set(ids)
        model.cursor = ids[0]
        model.openViewer()
        model.toggleCropOverlay()

        model.resetCropSelection()

        XCTAssertEqual(model.frame(ids[0])!.sidecar.geometry ?? GeometrySettings(), GeometrySettings(),
                       "the shown frame is back to no geometry")
        for id in ids.dropFirst() {
            XCTAssertEqual(model.frame(id)!.sidecar.geometry?.rotate, 90, "an off screen frame keeps its turn")
        }
        XCTAssertEqual(model.selection, Set(ids))
    }

    /// Turning it OFF changes no selection either, so neither direction is a selection event.
    @MainActor
    func testTurningTheCropOverlayOffLeavesTheSelectionAlone() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        seedDevelop(model, ids)
        model.cursor = ids[0]
        model.openViewer()
        model.toggleCropOverlay()
        model.selection = Set(ids)

        model.toggleCropOverlay()

        XCTAssertFalse(model.showsCropOverlay)
        XCTAssertEqual(model.selection, Set(ids), "off is not a selection event")
    }

    /// An undeveloped frame refuses the overlay, and the refusal leaves the selection
    /// untouched as well.
    @MainActor
    func testTheCropOverlayRefusedOnANegativeDoesNotChangeAnything() throws {
        let (model, ids) = try modelWithFolder(count: 3)   // nothing developed
        model.selection = Set(ids)
        model.cursor = ids[0]

        model.toggleCropOverlay()

        XCTAssertFalse(model.showsCropOverlay)
        XCTAssertEqual(model.selection, Set(ids))
    }

    // MARK: site 3, focusForContextMenu (GridActions.swift), KEEPS, conditionally

    /// A right click INSIDE the selection keeps all of it. This is Finder's rule.
    @MainActor
    func testARightClickInsideTheSelectionKeepsEveryFrame() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = Set(ids)

        model.focusForContextMenu(on: ids[2])

        XCTAssertEqual(model.selection, Set(ids))
    }

    /// A right click OUTSIDE it collapses onto the clicked frame, which is also Finder's
    /// rule and is what a user asking for that frame's menu means.
    @MainActor
    func testARightClickOutsideTheSelectionCollapsesOntoTheClickedFrame() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = [ids[0], ids[1]]

        model.focusForContextMenu(on: ids[2])

        XCTAssertEqual(model.selection, [ids[2]])
    }

    // MARK: helpers

    @MainActor
    private func modelWithFolder(count: Int = 3) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
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
    private func seedDevelop(_ model: AppModel, _ ids: [Frame.ID]) {
        for id in ids {
            model.undoManager.beginUndoGrouping()
            model.apply({ SidecarEdits.setDevelop($0, DevelopSettings(
                stock: "kodak-gold-200", tone: .flat, autoBalance: true,
                base: BaseSettings(mode: .anchor))) }, to: id, actionName: "seed")
            model.undoManager.endUndoGrouping()
        }
    }
}

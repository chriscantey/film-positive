import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// After a folder change, a click on a frame must show that frame in the right column.
///
/// The right column draws its controls only when `selectionSummary` is not empty, and the
/// summary is `selectedFrames`, which is the SELECTED folder's frames filtered by
/// `selection`, or by `viewerFrameID` alone while a closeup is showing. So an empty column
/// after a click means one of four things went stale across the folder change. Each test
/// below is one of those four, written as the exact sequence that would show it.
///
/// Every test drives the model with NO view mounted. The grid is not mounted while the
/// closeup is up, so a folder change made from the closeup has no view to clean up after it.
final class FolderSwitchInspectorTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: hypothesis 1, a viewer id left over from the other folder (THE CAUSE)

    /// Closeup open in A, pick B in the sidebar, click a frame in B. The content column
    /// shows B's grid (A's frame is not in B, so `viewerFrame` is nil), the click selects
    /// the frame, and the inspector must show it.
    ///
    /// A `viewerFrameID` still naming A's frame would make `selectedFrames` filter B's
    /// frames for an id they never have, and the column would be empty.
    @MainActor
    func testAFolderChangeFromTheCloseupLeavesNoViewerIdBehind() throws {
        let (model, a, b) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a.id)
        model.selectByClick(a.frames[1], modifiers: [])
        model.openViewer()
        XCTAssertEqual(model.viewerFrameID, a.frames[1])

        model.selectFolderFromSidebar(b.id)

        XCTAssertNil(model.viewerFrameID, "a different roll is a different closeup, and A's frame is not in it")
        XCTAssertNil(model.viewerFrame)

        model.selectByClick(b.frames[0], modifiers: [])

        XCTAssertEqual(model.selectedFrames.map(\.id), [b.frames[0]])
        XCTAssertFalse(model.selectionSummary.isEmpty, "the right column draws the frame that was clicked")
    }

    /// The same, with the arrow keys in the folder list and a double click into B's closeup
    /// afterwards: every folder change clears the viewer, whoever made it.
    @MainActor
    func testEveryFolderChangeClearsTheCloseupNotOnlyTheSidebarsOwn() throws {
        let (model, a, b) = try modelWithTwoFolders()
        model.selectedFolderID = a.id
        model.openViewer(on: a.frames[2])

        // Not through the sidebar: `addFolder` of a folder already listed selects it.
        model.addFolder(b.url)

        XCTAssertEqual(model.selectedFolderID, b.id)
        XCTAssertNil(model.viewerFrameID)
        model.openViewer(on: b.frames[1])
        XCTAssertEqual(model.selectedFrames.map(\.id), [b.frames[1]])
        XCTAssertFalse(model.selectionSummary.isEmpty)
    }

    /// Back to A after leaving its closeup by a folder change: the grid, not the old
    /// closeup springing back open on a frame nobody asked for.
    @MainActor
    func testGoingBackToTheFirstFolderDoesNotReopenItsCloseup() throws {
        let (model, a, b) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a.id)
        model.openViewer(on: a.frames[0])

        model.selectFolderFromSidebar(b.id)
        model.selectFolderFromSidebar(a.id)

        XCTAssertNil(model.viewerFrame, "the closeup was left when the folder changed")
        XCTAssertTrue(model.selection.isEmpty, "and nothing from before the change is still selected")
    }

    /// The closeup's own modes go with it, exactly as Done takes them: the next closeup
    /// opens on the picture, not in a crop nobody asked for.
    @MainActor
    func testTheCropOverlayGoesWithTheCloseupOnAFolderChange() throws {
        let (model, a, b) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a.id)
        model.openViewer(on: a.frames[0])
        model.showsCropOverlay = true

        model.selectFolderFromSidebar(b.id)

        XCTAssertFalse(model.showsCropOverlay)
    }

    /// Choosing the folder that is already selected is not a change, and must not throw
    /// away the selection or the closeup. The sidebar calls through on a click on the
    /// selected row.
    @MainActor
    func testReselectingTheSameFolderKeepsEverything() throws {
        let (model, a, _) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a.id)
        model.selection = Set(a.frames)
        model.openViewer(on: a.frames[1])

        model.selectedFolderID = a.id
        model.selectFolderFromSidebar(a.id)

        XCTAssertEqual(model.selection, Set(a.frames))
        XCTAssertEqual(model.viewerFrameID, a.frames[1])
    }

    // MARK: hypothesis 2, a selection restore racing the click (NOT the cause)

    /// Nothing restores a folder's selection later: the only thing remembered per folder is
    /// which folder was last open (`rememberSelectedFolder`). So a click after the change,
    /// and then a full turn of the run loop, still holds the click.
    @MainActor
    func testNothingAfterTheFolderChangeOverwritesTheClick() async throws {
        let (model, a, b) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a.id)
        model.selectByClick(a.frames[0], modifiers: [])

        model.selectFolderFromSidebar(b.id)
        model.selectByClick(b.frames[2], modifiers: [])
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.selection, [b.frames[2]])
        XCTAssertEqual(model.selectedFrames.map(\.id), [b.frames[2]])
        XCTAssertFalse(model.selectionSummary.isEmpty)
    }

    // MARK: hypothesis 3, A's ids still selected and a click that adds (NOT the cause)

    /// Even with A's ids and anchor left in place, every kind of click puts the clicked frame
    /// into the selection, so `selectedFrames` holds at least it. A shift click whose anchor
    /// is not in B falls back to a plain click.
    @MainActor
    func testEveryKindOfClickOnBSelectsTheClickedFrameWhateverAWasHolding() throws {
        let (model, a, b) = try modelWithTwoFolders()
        let modifiers: [GridSelection<Frame.ID>.Modifiers] = [[], [.shift], [.command], [.shift, .command]]
        for m in modifiers {
            model.selectFolderFromSidebar(a.id)
            model.selectFolderFromSidebar(b.id)
            // Put A's navigation back as if nothing had cleared it.
            model.selection = Set(a.frames)
            model.anchor = a.frames[0]
            model.cursor = a.frames[0]

            model.selectByClick(b.frames[1], modifiers: m)

            XCTAssertTrue(model.selectedFrames.map(\.id).contains(b.frames[1]), "modifiers \(m.rawValue)")
            XCTAssertFalse(model.selectionSummary.isEmpty, "modifiers \(m.rawValue)")
        }
    }

    // MARK: hypothesis 4, a selected folder with no session behind it (NOT the cause)

    /// `addFolder` appends the session BEFORE it selects it, and the sidebar lists only
    /// sessions, so the id it hands over always resolves. Asserted at the one moment it
    /// could fail: inside `selectedFolderID`'s own change.
    @MainActor
    func testTheSelectedFolderAlwaysResolvesTheMomentItIsChosen() throws {
        let (model, a, b) = try modelWithTwoFolders()
        for id in [a.id, b.id, a.id] {
            model.selectFolderFromSidebar(id)
            XCTAssertNotNil(model.selectedFolder)
            XCTAssertEqual(model.framesInView.count, 3)
        }
        let c = try makeRoll("c")
        let session = model.addFolder(c)
        XCTAssertEqual(model.selectedFolderID, session?.id)
        XCTAssertEqual(model.selectedFolder?.frames.count, 3, "the new folder resolves the moment it is selected")
    }

    // MARK: helpers

    private struct Roll { let id: FolderSession.ID; let url: URL; let frames: [Frame.ID] }

    private func makeRoll(_ name: String) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...3 {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        return dir
    }

    @MainActor
    private func modelWithTwoFolders() throws -> (AppModel, Roll, Roll) {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        var rolls: [Roll] = []
        for name in ["a", "b"] {
            let session = try XCTUnwrap(model.addFolder(try makeRoll(name)))
            XCTAssertEqual(session.frames.count, 3)
            rolls.append(Roll(id: session.id, url: session.url, frames: session.frames.map(\.id)))
        }
        return (model, rolls[0], rolls[1])
    }
}

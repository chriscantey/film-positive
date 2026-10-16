import XCTest
import FilmSidecar
@testable import FilmPositive

/// Evidence for arrow key navigation: the pure move rules, and the model's own behavior
/// over a real folder, which is what the grid and the viewer both call.
///
/// What these cannot prove is that a key press reaches the view at all, because that is
/// SwiftUI focus and needs a window. That half is verified on screen.
final class GridNavigationTests: XCTestCase {

    typealias Nav = GridNavigation<Int>
    private let order = Array(1...9)   // three rows of three at columns 3

    private func state(_ selected: Set<Int> = [], anchor: Int? = nil, cursor: Int? = nil) -> Nav.State {
        Nav.State(selected: selected, anchor: anchor, cursor: cursor)
    }

    // MARK: the pure rules

    func testRightAndLeftStepOneFrame() {
        let r = Nav.move(.right, order: order, state: state(cursor: 4), columns: 3)
        XCTAssertEqual(r, state([5], anchor: 5, cursor: 5))
        let l = Nav.move(.left, order: order, state: state(cursor: 4), columns: 3)
        XCTAssertEqual(l, state([3], anchor: 3, cursor: 3))
    }

    func testUpAndDownStepARow() {
        XCTAssertEqual(Nav.move(.down, order: order, state: state(cursor: 2), columns: 3)?.cursor, 5)
        XCTAssertEqual(Nav.move(.up, order: order, state: state(cursor: 8), columns: 3)?.cursor, 5)
        // a different layout moves by that layout's row
        XCTAssertEqual(Nav.move(.down, order: order, state: state(cursor: 2), columns: 4)?.cursor, 6)
        XCTAssertEqual(Nav.move(.down, order: order, state: state(cursor: 2), columns: 1)?.cursor, 3)
    }

    func testRowStepsOffTheEndsLandOnTheNearestEndInsteadOfRefusing() {
        // from the top row, up goes to the first frame; from the last full row, down goes
        // to the last frame even when the last row is short
        XCTAssertEqual(Nav.move(.up, order: order, state: state(cursor: 2), columns: 3)?.cursor, 1)
        XCTAssertEqual(Nav.move(.down, order: Array(1...8), state: state(cursor: 6), columns: 3)?.cursor, 8)
    }

    func testTheEdgesRefuseSoTheKeyGoesBackToTheSystem() {
        XCTAssertNil(Nav.move(.left, order: order, state: state(cursor: 1), columns: 3))
        XCTAssertNil(Nav.move(.right, order: order, state: state(cursor: 9), columns: 3))
        XCTAssertNil(Nav.move(.up, order: order, state: state(cursor: 1), columns: 3))
        XCTAssertNil(Nav.move(.down, order: order, state: state(cursor: 9), columns: 3))
        XCTAssertNil(Nav.move(.first, order: order, state: state(cursor: 1), columns: 3))
        XCTAssertNil(Nav.move(.right, order: [], state: state(), columns: 3))
    }

    func testFirstKeyWithNoCursorEntersFromTheEndTheKeyPointsAwayFrom() {
        XCTAssertEqual(Nav.move(.right, order: order, state: state(), columns: 3)?.cursor, 1)
        XCTAssertEqual(Nav.move(.down, order: order, state: state(), columns: 3)?.cursor, 1)
        XCTAssertEqual(Nav.move(.left, order: order, state: state(), columns: 3)?.cursor, 9)
        XCTAssertEqual(Nav.move(.up, order: order, state: state(), columns: 3)?.cursor, 9)
        // an anchor left by a click is a usable starting point
        XCTAssertEqual(Nav.move(.right, order: order, state: state([4], anchor: 4), columns: 3)?.cursor, 5)
    }

    func testHomeAndEndJumpToTheEnds() {
        XCTAssertEqual(Nav.move(.first, order: order, state: state(cursor: 5), columns: 3)?.cursor, 1)
        XCTAssertEqual(Nav.move(.last, order: order, state: state(cursor: 5), columns: 3)?.cursor, 9)
    }

    func testShiftExtendsFromTheAnchorAndKeepsIt() {
        var s = state([4], anchor: 4, cursor: 4)
        s = Nav.move(.right, order: order, state: s, columns: 3, extend: true)!
        XCTAssertEqual(s, state([4, 5], anchor: 4, cursor: 5))
        s = Nav.move(.right, order: order, state: s, columns: 3, extend: true)!
        XCTAssertEqual(s, state([4, 5, 6], anchor: 4, cursor: 6))
        // back over the anchor and out the other side: the run follows the cursor
        s = Nav.move(.first, order: order, state: s, columns: 3, extend: true)!
        XCTAssertEqual(s, state([1, 2, 3, 4], anchor: 4, cursor: 1))
        // without shift the run collapses to one frame and the anchor moves
        s = Nav.move(.right, order: order, state: s, columns: 3)!
        XCTAssertEqual(s, state([2], anchor: 2, cursor: 2))
    }

    func testShiftWithoutAnAnchorSelectsOne() {
        let s = Nav.move(.right, order: order, state: state(cursor: 4), columns: 3, extend: true)
        XCTAssertEqual(s, state([5], anchor: 5, cursor: 5))
    }

    func testPruneDropsWhatIsNoLongerOnScreen() {
        let s = Nav.prune(state([1, 2, 99], anchor: 99, cursor: 2), to: order)
        XCTAssertEqual(s, state([1, 2], anchor: nil, cursor: 2))
    }

    /// The row step has to match what the eye sees, so the column count is computed the
    /// way `GridItem(.adaptive(minimum:))` fills a row rather than guessed.
    func testColumnCountMatchesAnAdaptiveGrid() {
        // 800 wide, 16 padding each side, 16 spacing, 200 cells: 768 fits (200+16)*3 + 200
        XCTAssertEqual(Nav.columns(width: 800, cellWidth: 200, spacing: 16, padding: 16), 3)
        XCTAssertEqual(Nav.columns(width: 1000, cellWidth: 200, spacing: 16, padding: 16), 4)
        XCTAssertEqual(Nav.columns(width: 800, cellWidth: 110, spacing: 16, padding: 16), 6)
        XCTAssertEqual(Nav.columns(width: 300, cellWidth: 420, spacing: 16, padding: 16), 1)
        // degenerate inputs never produce a zero or negative row step
        XCTAssertEqual(Nav.columns(width: 0, cellWidth: 200, spacing: 16, padding: 16), 1)
        XCTAssertEqual(Nav.columns(width: 800, cellWidth: 0, spacing: 16, padding: 16), 1)
    }

    // MARK: the model, over a real folder

    @MainActor
    private func modelWithFolder(_ count: Int) throws -> (AppModel, [Frame.ID]) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 32).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        Preferences.store = InMemoryPreferences()
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        XCTAssertNotNil(model.addFolder(dir))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (model, model.framesInView.map(\.id))
    }

    @MainActor
    func testArrowsWalkTheFolderAndTheSelectionFollows() throws {
        let (model, ids) = try modelWithFolder(6)
        XCTAssertTrue(model.navigate(.right, columns: 3))
        XCTAssertEqual(model.selection, [ids[0]])
        XCTAssertEqual(model.cursor, ids[0])
        XCTAssertTrue(model.navigate(.right, columns: 3))
        XCTAssertEqual(model.selection, [ids[1]])
        XCTAssertTrue(model.navigate(.down, columns: 3))
        XCTAssertEqual(model.cursor, ids[4])
        XCTAssertTrue(model.navigate(.left, columns: 3, extend: true))
        XCTAssertEqual(model.selection, [ids[3], ids[4]])
        // down from the second row has no third row, so it lands on the last frame
        XCTAssertTrue(model.navigate(.down, columns: 3))
        XCTAssertEqual(model.selection, [ids[5]])
        XCTAssertFalse(model.navigate(.last, columns: 3), "already on the last frame")
        XCTAssertFalse(model.navigate(.down, columns: 3), "nothing below the last frame")
    }

    @MainActor
    func testAClickThenAnArrowContinuesFromTheClickedFrame() throws {
        let (model, ids) = try modelWithFolder(5)
        model.selectByClick(ids[2], modifiers: [])
        XCTAssertEqual(model.selection, [ids[2]])
        XCTAssertTrue(model.navigate(.right, columns: 5))
        XCTAssertEqual(model.selection, [ids[3]])
    }

    @MainActor
    func testViewerOpensOnTheCursorAndTheArrowsMoveItWithTheSelection() throws {
        let (model, ids) = try modelWithFolder(4)
        model.selectByClick(ids[1], modifiers: [])
        model.openViewer()
        XCTAssertEqual(model.viewerFrameID, ids[1])
        XCTAssertEqual(model.viewerFrame?.id, ids[1])
        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertEqual(model.viewerFrameID, ids[2])
        XCTAssertEqual(model.selection, [ids[2]], "the inspector follows the viewer")
        XCTAssertTrue(model.navigate(.right, columns: 1))
        XCTAssertFalse(model.navigate(.right, columns: 1), "the last frame is the end of the walk")
        model.closeViewer()
        XCTAssertNil(model.viewerFrameID)
        XCTAssertEqual(model.selection, [ids[3]], "closing the viewer keeps what it was showing")
    }

    @MainActor
    func testViewerOnAnEmptyFolderDoesNothing() throws {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.openViewer()
        XCTAssertNil(model.viewerFrameID)
        XCTAssertFalse(model.navigate(.right, columns: 1))
    }

    @MainActor
    func testChangingFolderClearsTheCursorAndTheViewer() throws {
        let (model, ids) = try modelWithFolder(3)
        model.selectByClick(ids[0], modifiers: [])
        model.openViewer()
        model.clearNavigation()
        XCTAssertNil(model.cursor)
        XCTAssertNil(model.anchor)
        XCTAssertNil(model.viewerFrameID)
        XCTAssertTrue(model.selection.isEmpty)
    }
}

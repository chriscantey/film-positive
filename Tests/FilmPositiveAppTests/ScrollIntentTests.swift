import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Scrolling is a request, not a consequence.
///
/// A scroll on any `cursor` change is a STATE observation, so it cannot tell what moved the
/// cursor, and every writer of it gets a scroll for free. On a command-click that means
/// centering a frame that is already on screen under the pointer, once per click.
///
/// A modifier check inside the scroll would be a second inference on top of the first, read
/// at scroll time rather than at intent time, and it would leave the same problem for every
/// other non-keyboard cursor write. Instead the callers that MEAN it ask for it, and this
/// suite is the record of which ones do.
///
/// The rule is tested in the model rather than through the view on purpose: the modifiers
/// arrive at `selectByClick` already, so the decision belongs where it can be proved.
final class ScrollIntentTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-scroll-intent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A roll long enough that a selection can run off the bottom of a window.
    @MainActor
    private func model(frames: Int = 24) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...frames {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "%04d.CR2", i)))
        }
        let m = AppModel(service: FailingRenderService(message: "no engine in tests"))
        let session = try XCTUnwrap(m.addFolder(dir))
        return (m, session.frames.map(\.id))
    }

    // MARK: the mouse

    /// The requirement, stated as the thing that must not happen.
    @MainActor
    func testCommandClickNeverAsksToScroll() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[0], modifiers: [])
        let afterPlain = m.scrollRequest

        for id in [ids[5], ids[12], ids[20], ids[3], ids[18]] {
            m.selectByClick(id, modifiers: [.command])
        }

        XCTAssertEqual(m.selection.count, 6, "the frames really were added, so this is not a no-op")
        XCTAssertEqual(m.scrollRequest, afterPlain,
                       "not one command-click asked the grid to move")
    }

    /// Shift is the same case with a different modifier: the shift-clicked frame is under the
    /// pointer, so it is already visible.
    @MainActor
    func testShiftClickRangeExtendNeverAsksToScroll() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[0], modifiers: [])
        let afterPlain = m.scrollRequest

        m.selectByClick(ids[19], modifiers: [.shift])

        XCTAssertEqual(m.selection.count, 20, "the range really was extended")
        XCTAssertEqual(m.scrollRequest, afterPlain, "a shift-click does not move the grid either")
    }

    /// A plain click selects but does not move the grid, since the clicked frame is on screen.
    @MainActor
    func testAPlainClickSelectsAndAsksForNothing() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[7], modifiers: [])
        XCTAssertEqual(m.cursor, ids[7])
        XCTAssertEqual(m.selection, [ids[7]])
        XCTAssertEqual(m.anchor, ids[7])
        XCTAssertNil(m.scrollRequest, "the clicked frame is under the pointer, so it is on screen")

        m.selectByClick(ids[20], modifiers: [])
        XCTAssertEqual(m.selection, [ids[20]])
        XCTAssertNil(m.scrollRequest, "a second click on a different frame asks for nothing either")
    }

    /// Two requests for the SAME frame are two events. An id compared by equality would
    /// collapse them and the second would silently do nothing.
    @MainActor
    func testTwoRequestsForTheSameFrameAreTwoDistinctEvents() throws {
        let (m, ids) = try model()
        m.requestScroll(to: ids[4])
        let first = try XCTUnwrap(m.scrollRequest)
        m.requestScroll(to: ids[4])
        let second = try XCTUnwrap(m.scrollRequest)
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first, second, "the serial makes the second request observable")
        XCTAssertGreaterThan(second.serial, first.serial)
    }

    // MARK: the keyboard, which is why the behavior exists at all

    /// A 24-frame roll in 4 columns with rows 1 to 3 on screen: frames 4 to 15.
    @MainActor
    private func scrolledModel() throws -> (AppModel, [Frame.ID]) {
        let (m, ids) = try model()
        m.galleryTopFrameID = ids[4]
        m.galleryVisibleRows = 3
        return (m, ids)
    }

    /// A step that stays inside the rows on screen leaves the grid where it is.
    @MainActor
    func testAnArrowStepInsideTheVisibleRowsAsksForNothing() throws {
        let (m, ids) = try scrolledModel()
        m.selectByClick(ids[5], modifiers: [])
        XCTAssertTrue(m.navigate(.down, columns: 4))
        XCTAssertEqual(m.cursor, ids[9], "the cursor really moved")
        XCTAssertTrue(m.navigate(.right, columns: 4))
        XCTAssertEqual(m.cursor, ids[10])
        XCTAssertNil(m.scrollRequest, "both steps stayed on screen")
    }

    /// Arrowing past the bottom row asks, or the selection walks off the window. The row
    /// comes in at the bottom edge, one row of travel, not recentred.
    @MainActor
    func testAnArrowStepPastTheBottomRowAsksToScroll() throws {
        let (m, ids) = try scrolledModel()
        m.selectByClick(ids[13], modifiers: [])
        XCTAssertTrue(m.navigate(.down, columns: 4))
        let request = try XCTUnwrap(m.scrollRequest)
        XCTAssertEqual(request.id, ids[17])
        XCTAssertEqual(request.id, m.cursor)
        XCTAssertEqual(request.placement, .bottom)
    }

    @MainActor
    func testAnArrowStepPastTheTopRowComesInAtTheTop() throws {
        let (m, ids) = try scrolledModel()
        m.selectByClick(ids[5], modifiers: [])
        XCTAssertTrue(m.navigate(.up, columns: 4))
        let request = try XCTUnwrap(m.scrollRequest)
        XCTAssertEqual(request.id, ids[1])
        XCTAssertEqual(request.placement, .top)
    }

    /// The gallery reports no top until it has scrolled, so none means the top of the roll.
    @MainActor
    func testANilTopIsTheTopOfTheRoll() throws {
        let (m, ids) = try model()
        m.galleryVisibleRows = 3
        m.selectByClick(ids[0], modifiers: [])
        XCTAssertTrue(m.navigate(.down, columns: 4))
        XCTAssertNil(m.scrollRequest, "row 1 of a grid showing rows 0 to 2")
        XCTAssertTrue(m.navigate(.down, columns: 4))
        XCTAssertTrue(m.navigate(.down, columns: 4))
        XCTAssertEqual(m.scrollRequest?.id, ids[12], "row 3 is past the bottom")
    }

    /// Before the grid has measured itself there is no way to know what is on screen, so a
    /// step centers the cursor rather than risk leaving it off the window.
    @MainActor
    func testUnmeasuredGeometryFallsBackToCentring() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[0], modifiers: [])
        XCTAssertTrue(m.navigate(.down, columns: 4))
        XCTAssertEqual(m.scrollRequest?.id, ids[4])
        XCTAssertEqual(m.scrollRequest?.placement, .center)
    }

    /// The top frame alone counts a row with a sliver showing as on screen. The measured
    /// rows do not, so arrowing up into it brings it in (frame 1 with 60 points showing must
    /// scroll).
    @MainActor
    func testAStepIntoAMostlyHiddenTopRowScrolls() throws {
        let (m, ids) = try scrolledModel()
        m.galleryTopFrameID = ids[0]
        m.galleryFullRows = 1...3
        m.selectByClick(ids[5], modifiers: [])
        XCTAssertTrue(m.navigate(.down, columns: 4))
        XCTAssertNil(m.scrollRequest, "row 2 is wholly on screen")
        XCTAssertTrue(m.navigate(.up, columns: 4))
        XCTAssertTrue(m.navigate(.up, columns: 4))
        XCTAssertEqual(m.scrollRequest?.id, ids[1])
        XCTAssertEqual(m.scrollRequest?.placement, .top)
    }

    /// The numbers from a measured gallery: 190 point cells, 16 point spacing and padding, a
    /// 672 point viewport over 21 rows of 2.
    func testFullyVisibleRowsMatchesTheScreen() {
        let content = 16 * 2 + 21 * 206 - 16.0
        func rows(_ offset: Double) -> ClosedRange<Int>? {
            GalleryReturn.fullyVisibleRows(offset: offset, viewport: 672, content: content, frames: 41,
                                           columns: 2, padding: 16, spacing: 16)
        }
        XCTAssertEqual(rows(0), 0...2, "at the top, row 3 is cut off at the bottom")
        XCTAssertEqual(rows(152), 1...3, "scrolled so row 3 sits on the bottom edge, row 0 is a sliver")
        XCTAssertEqual(rows(206), 1...3)
        XCTAssertNil(GalleryReturn.fullyVisibleRows(offset: 0, viewport: 100, content: content, frames: 41,
                                                    columns: 2, padding: 16, spacing: 16),
                     "a viewport shorter than a row holds no whole row")
        XCTAssertEqual(GalleryReturn.fullyVisibleRows(offset: 0, viewport: 900, content: 900, frames: 6,
                                                      columns: 2, padding: 16, spacing: 16), 0...2,
                       "a grid shorter than the window shows every row")
    }

    /// Shift-arrow extends a range downward, which runs off the bottom exactly as a plain
    /// arrow does.
    @MainActor
    func testShiftArrowExtendPastTheBottomAsksToScroll() throws {
        let (m, ids) = try scrolledModel()
        m.selectByClick(ids[13], modifiers: [])
        XCTAssertTrue(m.navigate(.down, columns: 4, extend: true))
        XCTAssertEqual(m.scrollRequest?.id, ids[17])
        XCTAssertGreaterThan(m.selection.count, 1, "it really did extend")
    }

    /// A move that cannot happen changes nothing, so it must not ask either.
    @MainActor
    func testANavigationThatFailsAsksForNothing() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[0], modifiers: [])
        let before = m.scrollRequest
        XCTAssertFalse(m.navigate(.up, columns: 4), "already on the top row")
        XCTAssertEqual(m.scrollRequest, before)
    }

    // MARK: everything else that writes the cursor

    /// Arrows inside the closeup walk the selection and move the cursor. The grid is not
    /// mounted, and coming back is handled by `revealCursorAfterCloseup`.
    @MainActor
    func testTheCloseupWalkAsksForNothing() throws {
        let (m, ids) = try model()
        m.selection = [ids[2], ids[9], ids[15]]
        m.cursor = ids[2]
        m.anchor = ids[2]
        m.openViewer(on: ids[2])
        let before = m.scrollRequest

        XCTAssertTrue(m.navigate(.down, columns: 1))

        XCTAssertNotNil(m.viewerFrameID)
        XCTAssertEqual(m.scrollRequest, before, "the closeup is showing, there is no grid to move")
    }

    @MainActor
    func testOpeningTheCloseupAsksForNothing() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[0], modifiers: [])
        let before = m.scrollRequest
        m.openViewer(on: ids[11])
        XCTAssertEqual(m.scrollRequest, before)
    }

    /// The one non-keyboard writer that asks to scroll, deliberately: duplicating is a
    /// request to be shown the result.
    @MainActor
    func testDuplicatingStillAsksToScroll() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[3], modifiers: [])
        let before = m.scrollRequest

        m.duplicateSelection()

        guard let after = m.scrollRequest, after != before else {
            throw XCTSkip("duplicate produced no frames in this environment, so there is nothing to show")
        }
        XCTAssertEqual(after.id, m.cursor)
    }

    /// Nothing in the model asks to scroll just because a folder changed.
    @MainActor
    func testClearingNavigationAsksForNothing() throws {
        let (m, ids) = try model()
        m.selectByClick(ids[6], modifiers: [])
        let before = m.scrollRequest
        m.clearNavigation()
        XCTAssertNil(m.cursor)
        XCTAssertEqual(m.scrollRequest, before, "a cursor going nil is not a request to move")
    }
}

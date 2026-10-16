import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// A folder chosen in the sidebar leaves the keyboard in the sidebar, Return hands it to the
/// gallery, Escape lets go of it, and a folder chosen any other way still gives the gallery
/// the keyboard.
///
/// The focus itself is SwiftUI's and cannot be driven without a window. What can be pinned is
/// the model's half: it tells the gallery where a folder change came from, or the gallery
/// takes focus on every one.
@MainActor
final class SidebarFocusTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-sidebar-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func modelWithTwoFolders() throws -> (AppModel, FolderSession.ID, FolderSession.ID) {
        let model = AppModel(service: FailingRenderService(message: "no engine in tests"))
        var ids: [FolderSession.ID] = []
        for name in ["roll-a", "roll-b"] {
            let dir = scratch.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ids.append(try XCTUnwrap(model.addFolder(dir)).id)
        }
        return (model, ids[0], ids[1])
    }

    func testTheGalleryRuleIsTheInverseOfTheSidebarHoldingTheKeyboard() {
        XCTAssertTrue(SidebarFocus.galleryTakesFocus(sidebarHasKeyboard: false))
        XCTAssertFalse(SidebarFocus.galleryTakesFocus(sidebarHasKeyboard: true))
    }

    func testAFolderChosenInTheSidebarKeepsTheKeyboardThere() throws {
        let (model, a, _) = try modelWithTwoFolders()
        let requests = model.focusGridRequest
        model.selectFolderFromSidebar(a)
        XCTAssertEqual(model.selectedFolderID, a)
        XCTAssertTrue(model.sidebarHasKeyboard)
        XCTAssertFalse(SidebarFocus.galleryTakesFocus(sidebarHasKeyboard: model.sidebarHasKeyboard))
        XCTAssertEqual(model.focusGridRequest, requests, "choosing a folder must not ask the gallery to take the keyboard")
    }

    func testReturnInTheSidebarHandsTheKeyboardToTheGallery() throws {
        let (model, a, _) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a)
        let requests = model.focusGridRequest
        model.returnFocusToGrid()
        XCTAssertFalse(model.sidebarHasKeyboard)
        XCTAssertEqual(model.focusGridRequest, requests + 1)
    }

    func testEscapeInTheSidebarLetsGoWithoutHandingTheKeyboardToTheGallery() throws {
        let (model, a, _) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a)
        let requests = model.focusGridRequest
        model.releaseSidebarKeyboard()
        XCTAssertFalse(model.sidebarHasKeyboard)
        XCTAssertEqual(model.focusGridRequest, requests, "Escape drops focus, it does not move it")
    }

    func testAFolderAddedFromOutsideTheSidebarStillLetsTheGalleryTakeTheKeyboard() throws {
        let (model, _, _) = try modelWithTwoFolders()
        XCTAssertFalse(model.sidebarHasKeyboard)
        XCTAssertTrue(SidebarFocus.galleryTakesFocus(sidebarHasKeyboard: model.sidebarHasKeyboard))
    }

    /// Clicking the row that is already selected focuses the list without a selection write.
    /// The list's own focus sets the flag, and the trash route reads it, so Command Backspace
    /// there does not trash the grid's frames.
    func testTheListTakingFocusWithoutASelectionChangeStillHoldsTheKeyboard() throws {
        let (model, a, _) = try modelWithTwoFolders()
        model.selectedFolderID = a
        model.sidebarHasKeyboard = false
        model.sidebarFocusChanged(true)
        XCTAssertTrue(model.sidebarHasKeyboard)
        XCTAssertEqual(FilmPositiveApp.trashRoute(textFieldHasFocus: false, sidebarHasKeyboard: model.sidebarHasKeyboard), .nothing)
        model.sidebarFocusChanged(false)
        XCTAssertFalse(model.sidebarHasKeyboard)
        XCTAssertEqual(FilmPositiveApp.trashRoute(textFieldHasFocus: false, sidebarHasKeyboard: model.sidebarHasKeyboard), .frames)
    }

    func testTheArrowKeysInTheSidebarWriteThroughTheSamePath() throws {
        let (model, a, b) = try modelWithTwoFolders()
        model.selectFolderFromSidebar(a)
        model.selectFolderFromSidebar(b)
        XCTAssertEqual(model.selectedFolderID, b)
        XCTAssertTrue(model.sidebarHasKeyboard)
    }
}

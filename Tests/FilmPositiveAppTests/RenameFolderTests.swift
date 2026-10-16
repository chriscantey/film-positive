import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Rename from the sidebar. A real model over a real temporary directory: the folder moves
/// on disk with its sidecars, the session follows it in place, undo and redo move it back
/// and forth, and every refusal leaves the disk exactly as it was. No window.
@MainActor
final class RenameFolderTests: XCTestCase {

    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-rename-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        try? fm.removeItem(at: scratch)
    }

    // MARK: helpers

    @discardableResult
    private func folder(_ name: String, _ files: [String] = ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2"]) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, f) in files.enumerated() {
            try Data(repeating: UInt8(0x40 + i), count: 64).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    private func names(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func model(_ dirs: URL...) -> AppModel {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        for d in dirs { XCTAssertNotNil(model.addFolder(d)) }
        return model
    }

    private func renamedID(_ outcome: FolderRenameOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> FolderSession.ID {
        guard case .renamed(let id) = outcome else {
            XCTFail("expected a rename, got \(outcome)", file: file, line: line)
            throw XCTSkip("no rename")
        }
        return id
    }

    /// The paths the remembered folder list resolves to, by last component.
    private func rememberedNames() -> [String] {
        Preferences.load().folderBookmarks.compactMap { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))?.lastPathComponent
        }
    }

    // MARK: the rename

    func testRenameMovesTheFolderOnDiskWithItsSidecars() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        let id = try renamedID(model.renameFolder(dir, to: "roll two"))

        XCTAssertEqual(names(scratch), ["roll two"], "the old name is gone from the parent")
        XCTAssertEqual(names(scratch.appendingPathComponent("roll two")), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2"],
                       "the frames and the sidecar moved inside the folder")
        XCTAssertEqual(id.lastPathComponent, "roll two")
        let session = try XCTUnwrap(model.folders.first)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.name, "roll two")
        XCTAssertEqual(session.frames.map(\.name), ["IMG_0001.CR2", "IMG_0002.CR2"])
        for f in session.frames {
            XCTAssertEqual(f.url.deletingLastPathComponent().lastPathComponent, "roll two")
            XCTAssertTrue(fm.fileExists(atPath: f.url.path), "\(f.name) is where the session says")
        }
    }

    func testRenameKeepsThePlaceInTheListTheFolderSelectionAndTheFrameSelection() throws {
        let a = try folder("a roll")
        let dir = try folder("roll one")
        let c = try folder("c roll")
        let model = model(a, dir, c)
        model.selectedFolderID = dir
        let second = try XCTUnwrap(model.selectedFolder?.frames.last)
        model.selection = [second.id]
        model.cursor = second.id
        model.anchor = second.id

        let id = try renamedID(model.renameFolder(dir, to: "roll two"))

        XCTAssertEqual(model.folders.map(\.name), ["a roll", "roll two", "c roll"], "same position in the list")
        XCTAssertEqual(model.selectedFolderID, id, "the selection stays on the renamed folder")
        let moved = id.appendingPathComponent("IMG_0002.CR2")
        XCTAssertEqual(model.selection, [moved], "the frame selection followed the new path")
        XCTAssertEqual(model.cursor, moved)
        XCTAssertEqual(model.anchor, moved)
        XCTAssertEqual(model.selectedFrames.map(\.name), ["IMG_0002.CR2"])
    }

    func testRenameWritesTheNewPathToTheRememberedFolderList() throws {
        let other = try folder("other")
        let dir = try folder("roll one")
        let model = model(other, dir)
        model.selectedFolderID = dir
        XCTAssertEqual(rememberedNames(), ["other", "roll one"])

        _ = try renamedID(model.renameFolder(dir, to: "roll two"))

        XCTAssertEqual(rememberedNames(), ["other", "roll two"], "persistFolders wrote a bookmark for the new path")
        XCTAssertEqual(Preferences.load().lastFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent }, "roll two",
                       "the folder reopened at launch is the renamed one")
    }

    func testUndoRenamesTheFolderBackAndRedoRenamesItAgain() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        model.undoManager.removeAllActions()
        _ = try renamedID(model.renameFolder(dir, to: "roll two"))
        XCTAssertEqual(model.undoManager.undoActionName, "Rename Folder")

        model.undoManager.undo()
        XCTAssertEqual(names(scratch), ["roll one"])
        XCTAssertEqual(names(dir), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2"])
        XCTAssertEqual(model.folders.map(\.name), ["roll one"])
        XCTAssertEqual(model.selectedFolder?.name, "roll one")
        XCTAssertEqual(model.undoManager.redoActionName, "Rename Folder")

        model.undoManager.redo()
        XCTAssertEqual(names(scratch), ["roll two"])
        XCTAssertEqual(model.folders.map(\.name), ["roll two"])
        XCTAssertEqual(model.selectedFolder?.name, "roll two")
        XCTAssertTrue(model.undoManager.canUndo)
    }

    func testAnUnchangedNameMovesNothingAndRegistersNoUndoStep() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        model.undoManager.removeAllActions()
        XCTAssertEqual(model.renameFolder(dir, to: "roll one"), .unchanged)
        XCTAssertEqual(model.renameFolder(dir, to: "  roll one\n"), .unchanged, "surrounding spaces do not count as a change")
        XCTAssertFalse(model.undoManager.canUndo)
        XCTAssertEqual(names(scratch), ["roll one"])
        XCTAssertEqual(model.folders.map(\.id), [dir])
    }

    func testAChangeOfCaseAloneRenamesTheFolder() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        let id = try renamedID(model.renameFolder(dir, to: "Roll One"))
        XCTAssertEqual(names(scratch), ["Roll One"])
        XCTAssertEqual(model.folders.map(\.id), [id])
    }

    // MARK: refusals

    private func assertRefused(_ typed: String, _ expected: FolderRename.Refusal?, file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = scratch.appendingPathComponent("roll one")
        // A fresh store per call, so the next model does not restore the last one's folder.
        Preferences.store = InMemoryPreferences()
        let model = model(dir)
        model.undoManager.removeAllActions()
        let before = names(scratch)
        let outcome = model.renameFolder(dir, to: typed)
        guard case .refused(let refusal) = outcome else {
            return XCTFail("expected a refusal for \(typed.debugDescription), got \(outcome)", file: file, line: line)
        }
        if let expected { XCTAssertEqual(refusal, expected, file: file, line: line) }
        XCTAssertEqual(names(scratch), before, "the disk is untouched", file: file, line: line)
        XCTAssertEqual(names(dir), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2"], file: file, line: line)
        XCTAssertEqual(model.folders.map(\.id), [dir], file: file, line: line)
        XCTAssertFalse(model.undoManager.canUndo, "a refusal adds no undo step", file: file, line: line)
    }

    func testAnEmptyNameIsRefused() throws {
        try folder("roll one")
        try assertRefused("", .empty)
        try assertRefused("   ", .empty)
    }

    func testANameWithASlashOrAColonIsRefused() throws {
        try folder("roll one")
        try assertRefused("roll/two", .badCharacter)
        try assertRefused("roll:two", .badCharacter)
    }

    func testANameTakenInTheParentIsRefusedWhateverItsCase() throws {
        try folder("roll one")
        try folder("Roll Two", [])
        try assertRefused("roll two", .taken("Roll Two"))
    }

    func testAMoveThePermissionsRefuseIsRefused() throws {
        try folder("roll one")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path) }
        try assertRefused("roll two", nil)
    }

    func testRenameIsBlockedWithAReasonWhenTheParentCannotBeWritten() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        XCTAssertNil(model.renameBlocker(dir))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path) }
        let why = try XCTUnwrap(model.renameBlocker(dir))
        XCTAssertTrue(why.contains("cannot be written"), why)
        model.beginRename(dir)
        XCTAssertNil(model.renamingFolderID, "a blocked folder does not open the name field")
    }

    // MARK: the name field

    func testARefusedCommitKeepsTheFieldOpenAndSaysWhy() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        model.beginRename(dir)
        XCTAssertEqual(model.renamingFolderID, dir)

        XCTAssertFalse(model.commitRename("roll/two"))
        XCTAssertEqual(model.renamingFolderID, dir, "the field stays open")
        XCTAssertEqual(model.renameRefusals, 1, "one shake")
        XCTAssertEqual(model.notice, FolderRename.Refusal.badCharacter.sentence)
        XCTAssertNil(model.lastError, "a refusal is never an alert")

        XCTAssertTrue(model.commitRename("roll two"))
        XCTAssertNil(model.renamingFolderID)
        XCTAssertEqual(names(scratch), ["roll two"])
    }

    func testCancelClosesTheFieldWithNoChange() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        model.undoManager.removeAllActions()
        model.beginRename(dir)
        model.cancelRename()
        XCTAssertNil(model.renamingFolderID)
        XCTAssertEqual(names(scratch), ["roll one"])
        XCTAssertFalse(model.undoManager.canUndo)
    }

    // MARK: what travels with the folder

    func testTheSweepAfterARenameDoesNotBringBackTheOldPath() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        let id = try renamedID(model.renameFolder(dir, to: "roll two"))

        XCTAssertEqual(model.sweepFolders(), [], "the renamed folder is not reported gone")
        model.rescan(id)
        XCTAssertNil(model.notice)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.folders.map(\.id), [id])
        XCTAssertEqual(model.folders.first?.frames.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: dir.path), "nothing recreated the old folder")
        XCTAssertEqual(rememberedNames(), ["roll two"])
    }

    func testTheColourTagTravelsWithTheFolder() throws {
        let dir = try folder("roll one")
        let model = model(dir)
        model.setFolderColour(.green, for: dir)
        XCTAssertEqual(model.folderColours[dir], .green)

        let id = try renamedID(model.renameFolder(dir, to: "roll two"))

        XCTAssertEqual(FolderColour.read(id), .green, "the tag is on the folder on disk")
        XCTAssertEqual(model.folderColours[id], .green)
        XCTAssertNil(model.folderColours[dir])
    }

    func testAListedFolderInsideTheRenamedOneFollowsIt() throws {
        let dir = try folder("roll one")
        let inner = try folder("roll one/keepers", ["IMG_0009.CR2"])
        let model = model(dir, inner)

        _ = try renamedID(model.renameFolder(dir, to: "roll two"))

        XCTAssertEqual(model.folders.map(\.name), ["roll two", "keepers"])
        let moved = try XCTUnwrap(model.folders.last)
        XCTAssertEqual(moved.url.deletingLastPathComponent().lastPathComponent, "roll two")
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(moved.frames.first).url.path))
        XCTAssertEqual(model.sweepFolders(), [])
    }
}

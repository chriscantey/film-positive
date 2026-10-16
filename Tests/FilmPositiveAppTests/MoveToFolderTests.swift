import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Move to Folder. The planner over a real temporary directory, then the model
/// following the files: the list, the selection and undo. No window.
final class MoveToFolderTests: XCTestCase {

    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-move-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? fm.removeItem(at: scratch)
    }

    // MARK: helpers

    @discardableResult
    private func folder(_ name: String, _ files: [String]) throws -> URL {
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

    @MainActor
    private func model(_ dir: URL) -> AppModel {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        return model
    }

    private let develop = DevelopSettings(stock: "kodak-gold-200", autoTone: false,
                                          base: BaseSettings(mode: .anchor, anchor: 4000, ratios: BaseRatios(rg: 0.4764, bg: 0.7156)))

    // MARK: the planner

    func testTheSidecarsTravelWithTheirRawAndNothingElseDoes() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2", "IMG_0002.fprc", "IMG_0002.JPG", "notes.txt"])
        let dest = try folder("roll/keepers", [])
        let plan = try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2"),
                                              src.appendingPathComponent("IMG_0002.CR2")], to: dest)
        XCTAssertEqual(plan.frames.map { $0.steps.map(\.from.lastPathComponent) },
                       [["IMG_0001.CR2", "IMG_0001.xmp"], ["IMG_0002.CR2", "IMG_0002.fprc"]])
        XCTAssertEqual(names(src), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2", "IMG_0002.JPG", "IMG_0002.fprc", "keepers", "notes.txt"], "planning touches nothing")

        let outcome = plan.run()
        XCTAssertEqual(outcome.problems, [])
        XCTAssertEqual(outcome.moved.count, 2)
        XCTAssertEqual(names(src), ["IMG_0002.JPG", "keepers", "notes.txt"], "a camera JPEG is its own picture and stays")
        XCTAssertEqual(names(dest), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2", "IMG_0002.fprc"])
    }

    func testAnyTakenNameRefusesTheWholeBatchBeforeAFileMoves() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0002.xmp"])
        // A sidecar alone, in another case: the volume is case-insensitive, so it counts.
        let dest = try folder("elsewhere", ["img_0002.XMP"])
        XCTAssertThrowsError(try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2"),
                                                        src.appendingPathComponent("IMG_0002.CR2")], to: dest)) { error in
            XCTAssertEqual(error as? MovePlan.Refusal, .taken(["IMG_0002.xmp"]))
        }
        XCTAssertEqual(names(src), ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0002.xmp"], "IMG_0001 did not move either")
        XCTAssertEqual(names(dest), ["img_0002.XMP"])
    }

    func testTheSameFolderIsRefused() throws {
        let src = try folder("roll", ["IMG_0001.CR2"])
        XCTAssertThrowsError(try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2")], to: src)) {
            XCTAssertEqual($0 as? MovePlan.Refusal, .sameFolder)
        }
    }

    func testASharedSidecarMovesOnceOrNotAtAll() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0001.DNG", "IMG_0001.xmp"])
        let dest = try folder("out", [])
        XCTAssertThrowsError(try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2")], to: dest)) {
            XCTAssertEqual($0 as? MovePlan.Refusal, .sharedSidecar(moving: "IMG_0001.CR2", staying: "IMG_0001.DNG"))
        }
        let both = try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2"),
                                              src.appendingPathComponent("IMG_0001.DNG")], to: dest)
        XCTAssertEqual(both.frames.flatMap(\.steps).map(\.to.lastPathComponent), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0001.DNG"])
        XCTAssertEqual(both.run().problems, [])
        XCTAssertEqual(names(dest), ["IMG_0001.CR2", "IMG_0001.DNG", "IMG_0001.xmp"])
        XCTAssertEqual(names(src), [])
    }

    /// Another volume cannot take a rename, so the file is copied and the original removed.
    /// Forced here, on one disk, through the injected volume test.
    func testTheCrossVolumePathCopiesThenRemoves() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0001.xmp"])
        let dest = try folder("usb", [])
        let before = try Data(contentsOf: src.appendingPathComponent("IMG_0001.CR2"))
        let plan = try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2")], to: dest,
                                     sameVolume: { _, _ in false })
        XCTAssertFalse(plan.sameVolume)
        XCTAssertEqual(plan.run().problems, [])
        XCTAssertEqual(names(src), [])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("IMG_0001.CR2")), before, "byte for byte")
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("IMG_0001.xmp").path))
    }

    /// A step that fails part way puts the frame's finished steps back, so the raw and its
    /// sidecar end up together, and says which file.
    func testAFrameThatFailsHalfwayIsPutBackWhole() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2"])
        let dest = try folder("out", [])
        let plan = try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2"),
                                              src.appendingPathComponent("IMG_0002.CR2")], to: dest)
        // Something lands in the destination between planning and moving.
        try Data([1]).write(to: dest.appendingPathComponent("IMG_0001.xmp"))
        let outcome = plan.run()
        XCTAssertEqual(outcome.moved.map(\.from.lastPathComponent), ["IMG_0002.CR2"])
        XCTAssertEqual(outcome.problems.count, 1)
        XCTAssertTrue(outcome.problems[0].contains("IMG_0001.xmp"), outcome.problems[0])
        XCTAssertEqual(names(src), ["IMG_0001.CR2", "IMG_0001.xmp"], "the half-moved frame came back whole")
        XCTAssertEqual(names(dest), ["IMG_0001.xmp", "IMG_0002.CR2"])
    }

    func testTheUndoPlanIsTheSameMoveBackwards() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0001.xmp"])
        let dest = try folder("roll/sub", [])
        let plan = try MovePlan.make(moving: [src.appendingPathComponent("IMG_0001.CR2")], to: dest)
        _ = plan.run()
        let back = try MovePlan.make(moving: plan.reverseRaws, to: plan.sourceFolder)
        XCTAssertEqual(back.frames[0].steps.map(\.to.lastPathComponent), ["IMG_0001.CR2", "IMG_0001.xmp"])
        XCTAssertEqual(back.destination.path, src.standardizedFileURL.path)
        XCTAssertEqual(back.run().problems, [])
        XCTAssertEqual(names(src), ["IMG_0001.CR2", "IMG_0001.xmp", "sub"])
    }

    // MARK: the model

    @MainActor
    func testMovingASelectionListsTheFolderKeepsTheRollAndUndoesAsOneStep() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        let dest = try folder("roll/keepers", [])
        let m = model(src)
        let sourceID = try XCTUnwrap(m.selectedFolderID)
        let ids = m.framesInView.map(\.id)
        m.selection = [ids[0], ids[2]]
        // An edit still inside the 400 ms save window has to arrive with the file.
        m.applyToSelection({ SidecarEdits.setDevelop($0, self.develop) }, actionName: "seed")
        m.moveSelection(to: dest)

        XCTAssertNil(m.lastError)
        XCTAssertEqual(names(src), ["IMG_0002.CR2", "keepers"])
        XCTAssertEqual(names(dest), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0003.CR2", "IMG_0003.xmp"])
        XCTAssertEqual(m.selectedFolderID, sourceID, "the roll being sorted stays on screen")
        XCTAssertEqual(m.selection, [])
        XCTAssertEqual(m.framesInView.map(\.name), ["IMG_0002.CR2"])
        let listed = try XCTUnwrap(m.listedFolder(at: dest), "the destination joined the sidebar")
        XCTAssertEqual(listed.frames.map(\.name), ["IMG_0001.CR2", "IMG_0003.CR2"])
        XCTAssertEqual(listed.frames.first?.sidecar.develop?.stock, "kodak-gold-200")
        let onDisk = try XCTUnwrap(SidecarStore().load(for: dest.appendingPathComponent("IMG_0001.CR2")))
        XCTAssertEqual(onDisk.sidecar.develop?.stock, "kodak-gold-200", "the unsaved edit was written before the move")

        XCTAssertEqual(m.undoManager.undoActionName, "Move to Folder")
        m.undoManager.undo()
        XCTAssertEqual(names(src), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0002.CR2", "IMG_0003.CR2", "IMG_0003.xmp", "keepers"])
        XCTAssertEqual(names(dest), [], "the folder itself stays on disk")
        XCTAssertNil(m.listedFolder(at: dest), "and leaves the sidebar, since the move put it there")
        XCTAssertEqual(m.framesInView.map(\.name), ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        XCTAssertEqual(Set(m.selection.map(\.lastPathComponent)), ["IMG_0001.CR2", "IMG_0003.CR2"], "the frames that came home are selected")

        m.undoManager.redo()
        XCTAssertEqual(names(dest), ["IMG_0001.CR2", "IMG_0001.xmp", "IMG_0003.CR2", "IMG_0003.xmp"])
        XCTAssertNotNil(m.listedFolder(at: dest))
    }

    @MainActor
    func testMovingEveryFrameFollowsThemToTheirNewFolder() throws {
        let src = try folder("roll", ["IMG_0001.CR2", "IMG_0002.CR2"])
        let dest = try folder("sorted", [])
        let m = model(src)
        m.selection = Set(m.framesInView.map(\.id))
        m.moveSelection(to: dest)
        XCTAssertEqual(m.selectedFolder?.url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(m.framesInView.map(\.name), ["IMG_0001.CR2", "IMG_0002.CR2"])
        XCTAssertEqual(m.folders.count, 2, "the emptied roll stays listed")
    }

    @MainActor
    func testAListedDestinationTakesTheFramesInNameOrder() throws {
        let src = try folder("roll", ["IMG_0002.CR2", "IMG_0004.CR2"])
        let dest = try folder("other", ["IMG_0001.CR2", "IMG_0003.CR2"])
        let m = model(src)
        let sourceID = try XCTUnwrap(m.selectedFolderID)
        XCTAssertNotNil(m.addFolder(dest, select: false))
        XCTAssertEqual(m.selectedFolderID, sourceID, "select: false leaves the screen alone")
        m.selection = Set(m.framesInView.prefix(1).map(\.id))
        m.moveSelection(to: dest)
        XCTAssertEqual(m.folders.count, 2)
        XCTAssertEqual(m.listedFolder(at: dest)?.frames.map(\.name), ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        m.undoManager.undo()
        XCTAssertNotNil(m.listedFolder(at: dest), "a folder the user listed stays listed after undo")
        XCTAssertEqual(m.listedFolder(at: dest)?.frames.map(\.name), ["IMG_0001.CR2", "IMG_0003.CR2"])
    }

    @MainActor
    func testARefusalSaysWhyAndMovesNothing() throws {
        let src = try folder("roll", ["IMG_0001.CR2"])
        let dest = try folder("full", ["IMG_0001.CR2"])
        let m = model(src)
        m.selection = Set(m.framesInView.map(\.id))
        m.moveSelection(to: dest)
        XCTAssertEqual(m.lastError, "Nothing was moved. That folder already has IMG_0001.CR2.")
        XCTAssertEqual(m.framesInView.count, 1)
        XCTAssertNil(m.listedFolder(at: dest))
        XCTAssertFalse(m.undoManager.canUndo)
    }
}

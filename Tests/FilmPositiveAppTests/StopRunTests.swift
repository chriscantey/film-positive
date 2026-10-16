import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// One Stop, `AppModel.stopRun`, for both wands and Detect Crop. The run ends at its next
/// check between frames, the frame whose read was under way is not written, what already
/// landed stays, and the run's one undo step covers exactly that.
///
/// The frames in these rolls cannot render, so the reads are stood in for through the two
/// loops' seams, `runWand`'s `read` and `runCrop`'s `find`, which is also where a test presses
/// Stop in the middle of a frame.
final class StopRunTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func bytes(_ m: AppModel, _ ids: [Frame.ID]) throws -> [Data] {
        try ids.map { try XCTUnwrap(m.frame($0)).sidecar.encoded() }
    }

    private enum Wand: CaseIterable {
        case enhance, color
        var actionName: String { self == .enhance ? "Auto Enhance" : "Neutralize Cast" }

        func edit(_ i: Int) -> (Sidecar) -> Sidecar {
            switch self {
            case .enhance:
                let p = AutoEnhance.Proposal(blackPoint: 0.1 + 0.1 * Double(i), brightness: 0.2, highlights: -0.1,
                                             saturation: 0.1, vibrance: 0.05)
                return { AppModel.autoEnhanceEdit($0, p) }
            case .color:
                let wt = WarmthTint(warmth: 0.1 + 0.05 * Double(i), tint: -0.04)
                return { SidecarEdits.applyColorAuto($0, wt) }
            }
        }
    }

    /// A distinct crop per frame, so a restore that put one frame's crop on another would show.
    private func crop(_ i: Int) -> GeometrySettings {
        GeometrySettings(rotate: 0, flip: false, straightenDegrees: 0.2 + 0.1 * Double(i),
                         crop: CropRect(x: 0.1, y: 0.1, w: 0.7, h: 0.6))
    }

    /// (a) and (b): Stop pressed while frame 2 is being read. Frame 1 stays written, frame 2's
    /// result is dropped, frame 3 is never read, the spinner clears, and one Undo takes frame 1
    /// back and is the only step there is.
    @MainActor
    func testAStopDuringFrameTwoKeepsFrameOneOnlyForBothWands() async throws {
        for wand in Wand.allCases {
            let (m, ids) = try scratchRollModel(frames: 3, in: scratch, name: "roll-a-\(wand)")
            let before = try bytes(m, ids)
            var read: [Int] = []
            await m.runWand(ids.enumerated().map { ($1, $0) }, actionName: wand.actionName) { i in
                read.append(i)
                if i == 1 {
                    XCTAssertTrue(m.enhanceRunning, "\(wand): the run is going, so Stop takes")
                    m.stopRun()
                    XCTAssertTrue(m.stopRequested)
                }
                return wand.edit(i)
            }
            XCTAssertEqual(read, [0, 1], "\(wand): frame 3 is never read")
            let after = try bytes(m, ids)
            XCTAssertNotEqual(after[0], before[0], "\(wand): frame 1 landed before the press and stays")
            XCTAssertEqual(after[1], before[1], "\(wand): frame 2, read at the press, is not written")
            XCTAssertEqual(after[2], before[2], "\(wand): frame 3 is untouched")
            XCTAssertFalse(m.enhanceRunning, "\(wand): the spinner clears")
            XCTAssertNil(m.enhanceReading)
            XCTAssertFalse(m.stopRequested, "\(wand): the flag clears with the run")
            XCTAssertEqual(m.undoManager.undoActionName, wand.actionName)

            m.undoManager.undo()
            XCTAssertEqual(try bytes(m, ids), before, "\(wand): one Undo restores frame 1, byte for byte")
            XCTAssertFalse(m.undoManager.canUndo, "\(wand): the stopped run was exactly one step")
            m.undoManager.redo()
            XCTAssertEqual(try bytes(m, ids), after, "\(wand): one Redo writes frame 1 again and only it")
        }
    }

    /// (c): Stop pressed while frame 2's crop is being found. Frame 1's crop stays, frame 2's
    /// is dropped, frame 3 is never looked at, the sheet's progress clears, and one Undo
    /// takes frame 1's crop back.
    @MainActor
    func testAStopDuringACropRunKeepsTheCropsAlreadyWritten() async throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        let before = try bytes(m, ids)
        let frames = try ids.map { try XCTUnwrap(m.frame($0)) }
        var found: [Frame.ID] = []
        await m.runCrop(frames) { frame in
            found.append(frame.id)
            XCTAssertEqual(m.autoCropping, frame.id, "the cell being worked is marked")
            let i = ids.firstIndex(of: frame.id) ?? 0
            if i == 1 { m.stopRun() }
            return self.crop(i)
        }
        XCTAssertEqual(found, [ids[0], ids[1]], "frame 3 is never looked at")
        XCTAssertEqual(m.frame(ids[0])?.sidecar.geometry?.straightenDegrees ?? 0, 0.2, accuracy: 1e-9,
                       "frame 1's crop stays")
        let after = try bytes(m, ids)
        XCTAssertEqual(after[1], before[1], "frame 2, found at the press, is not written")
        XCTAssertEqual(after[2], before[2], "frame 3 is untouched")
        XCTAssertNil(m.autoCropping)
        XCTAssertNil(m.autoCropProgress, "the sheet's progress clears")
        XCTAssertFalse(m.stopRequested)
        XCTAssertEqual(m.undoManager.undoActionName, "Detect Crop")

        m.undoManager.undo()
        XCTAssertEqual(try bytes(m, ids), before, "one Undo restores frame 1's crop")
        XCTAssertFalse(m.undoManager.canUndo, "the stopped run was exactly one step")
    }

    /// (d): Stop pressed while the FIRST frame is read writes nothing and registers no step,
    /// for both wands and for crop, so Undo still reaches the step under the run.
    @MainActor
    func testAStopBeforeAnythingIsWrittenRegistersNoStep() async throws {
        for wand in Wand.allCases {
            let (m, ids) = try scratchRollModel(frames: 3, in: scratch, name: "roll-d-\(wand)")
            let before = try bytes(m, ids)
            await m.runWand(ids.enumerated().map { ($1, $0) }, actionName: wand.actionName) { i in
                m.stopRun()
                return wand.edit(i)
            }
            XCTAssertEqual(try bytes(m, ids), before, "\(wand): nothing written")
            XCTAssertFalse(m.undoManager.canUndo, "\(wand): and no step registered")
            XCTAssertFalse(m.enhanceRunning)
            XCTAssertFalse(m.stopRequested)
        }

        let (m, ids) = try scratchRollModel(frames: 3, in: scratch, name: "roll-d-crop")
        // a hand step under the run, so an empty crop step would show as a different name
        m.selection = [ids[2]]
        let contrast = try XCTUnwrap(EnhanceControl.all.first { $0.id == "contrast" })
        m.applyToSelection({ SidecarEdits.setEnhance($0, contrast.setting($0.enhance ?? .identity, to: 0.2)) },
                           actionName: contrast.label)
        let before = try bytes(m, ids)
        let frames = try ids.map { try XCTUnwrap(m.frame($0)) }
        await m.runCrop(frames) { frame in
            m.stopRun()
            return self.crop(0)
        }
        XCTAssertEqual(try bytes(m, ids), before, "crop: nothing written")
        XCTAssertEqual(m.undoManager.undoActionName, contrast.label, "crop: the empty run left no step")
        m.undoManager.undo()
        XCTAssertFalse(m.undoManager.canUndo, "crop: the hand step was the only one")
        XCTAssertNil(m.autoCropProgress)
        XCTAssertFalse(m.stopRequested)
    }

    /// The same hole without a Stop: a crop run where no frame is found leaves no empty
    /// "Detect Crop" step over the step under it, because the group opens at the first write.
    @MainActor
    func testACropRunThatFindsNothingRegistersNoStep() async throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        let frames = try ids.map { try XCTUnwrap(m.frame($0)) }
        await m.runCrop(frames) { _ in nil }
        XCTAssertFalse(m.undoManager.canUndo, "nothing found, no step")
        XCTAssertEqual(m.undoManager.groupingLevel, 0, "and no group left open")
    }

    /// Stop with no run going does nothing, so it cannot end the next run before its first
    /// frame, and a run after a stopped one goes all the way through.
    @MainActor
    func testAStopWithNoRunIsANoOpAndTheNextRunIsWhole() async throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        m.stopRun()
        XCTAssertFalse(m.stopRequested, "no run, no flag")

        await m.runWand(ids.enumerated().map { ($1, $0) }, actionName: "Auto Enhance") { i in
            if i == 0 { m.stopRun() }
            return Wand.enhance.edit(i)
        }
        let before = try bytes(m, ids)
        var read = 0
        await m.runWand(ids.enumerated().map { ($1, $0) }, actionName: "Auto Enhance") { i in
            read += 1
            return Wand.enhance.edit(i + 10)
        }
        XCTAssertEqual(read, 3, "the run after a stop reads every frame")
        let after = try bytes(m, ids)
        for i in 0..<3 { XCTAssertNotEqual(after[i], before[i], "frame \(i) written by the whole run") }
    }

    /// (e): both loops test the flag before a frame is read and again before it is written,
    /// Detect Crop goes through the loop that does, and every Stop surface calls `stopRun`.
    func testBothLoopsCheckTheFlagAndEverySurfaceCallsStopRun() throws {
        func body(_ file: String, _ entry: String) throws -> String {
            let s = try repoSource(file)
            let start = try XCTUnwrap(s.range(of: entry), entry)
            let rest = s[start.upperBound...]
            return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        }
        let wand = try body("Sources/FilmPositive/App/AppModel+AutoEnhance.swift", "func runWand<Job>(")
        let crop = try body("Sources/FilmPositive/App/AppModel.swift", "func runCrop(")
        for (name, loop) in [("runWand", wand), ("runCrop", crop)] {
            XCTAssertEqual(loop.components(separatedBy: "if stopRequested { break }").count - 1, 2,
                           "\(name) checks the flag before the read and before the write")
            XCTAssertTrue(loop.contains("stopRequested = false"), "\(name) clears the flag when it returns")
        }
        let entry = try body("Sources/FilmPositive/App/AppModel.swift", "func autoCropSelection(")
        XCTAssertTrue(entry.contains("await runCrop("), "Detect Crop runs through the loop that checks")

        let stop = try repoSource("Sources/FilmPositive/UI/Inspector/WandStopButton.swift")
        XCTAssertTrue(stop.contains("model.stopRun()"))
        XCTAssertTrue(stop.contains(".help(Self.help)"))
        XCTAssertEqual(WandStopButton.help, "Stop")
        let wands = try repoSource("Sources/FilmPositive/UI/Inspector/AutoEnhanceButton.swift")
        XCTAssertTrue(wands.contains(".accessibilityIdentifier(\"enhance.auto.stop\")"))
        XCTAssertTrue(wands.contains(".accessibilityIdentifier(\"enhance.neutralise.stop\")"))
        let sheet = try repoSource("Sources/FilmPositive/UI/Crop/AutoCropSheet.swift")
        XCTAssertTrue(sheet.contains("Button(running ? \"Stop\" : \"Cancel\""), "Cancel reads Stop while running")
        XCTAssertTrue(sheet.contains("if running { model.stopRun() } else { dismiss() }"))
        for file in ["Sources/FilmPositive/UI/Grid/GridView.swift", "Sources/FilmPositive/UI/Viewer/ViewerView.swift"] {
            let s = try repoSource(file)
            let esc = try XCTUnwrap(s.range(of: "case .escape:"), file)
            let next = String(s[esc.upperBound...].prefix(400))
            XCTAssertTrue(next.contains("if model.enhanceRunning { model.stopRun(); return .handled }"),
                          "\(file): Escape stops a run before it does anything else")
        }
    }
}

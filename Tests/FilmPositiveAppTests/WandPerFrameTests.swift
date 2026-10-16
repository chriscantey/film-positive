import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Both wands show each frame's result as its spinner clears, and the whole run is still one
/// Undo. Reading every frame and writing them all at once after the last would clear each
/// spinner on a frame that looks unchanged.
///
/// The frames in these rolls cannot render, so the render and the solve are stood in for by
/// `runWand`'s `read`, which is also where a test can look at the model between two frames.
final class WandPerFrameTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A different proposal per frame, so a restore that put one frame's values on another
    /// would show.
    private func proposal(_ i: Int) -> AutoEnhance.Proposal {
        AutoEnhance.Proposal(blackPoint: 0.1 + 0.1 * Double(i), brightness: 0.2, highlights: -0.1,
                             saturation: 0.1, vibrance: 0.05)
    }

    private func pair(_ i: Int) -> WarmthTint {
        WarmthTint(warmth: 0.1 + 0.05 * Double(i), tint: -0.04)
    }

    @MainActor
    private func bytes(_ m: AppModel, _ ids: [Frame.ID]) throws -> [Data] {
        try ids.map { try XCTUnwrap(m.frame($0)).sidecar.encoded() }
    }

    /// The two wands, as `runWand` edits: what each writes for frame `i`.
    private enum Wand: CaseIterable {
        case enhance, color
        var actionName: String { self == .enhance ? "Auto Enhance" : "Neutralize Cast" }
    }

    private func edit(_ wand: Wand, _ i: Int) -> (Sidecar) -> Sidecar {
        switch wand {
        case .enhance: let p = proposal(i); return { AppModel.autoEnhanceEdit($0, p) }
        case .color: let wt = pair(i); return { SidecarEdits.applyColorAuto($0, wt) }
        }
    }

    @MainActor
    private func written(_ wand: Wand, _ m: AppModel, _ id: Frame.ID) -> Bool {
        guard let s = m.frame(id)?.sidecar else { return false }
        switch wand {
        case .enhance: return s.look == SidecarEdits.autoLookID
        case .color: return s.colorAuto != nil
        }
    }

    /// (a) and (c): frame 1 is written, with its thumbnail's render invalidated and its save
    /// scheduled, BEFORE frame 2 is read. The spinner is on frame 2 while frame 1 already
    /// shows its result.
    @MainActor
    func testEachFrameIsWrittenBeforeTheNextIsRead() async throws {
        for wand in Wand.allCases {
            let (m, ids) = try scratchRollModel(frames: 2, in: scratch, name: "roll-a-\(wand)")
            var seen: [(first: Bool, second: Bool, reading: Frame.ID?)] = []
            await m.runWand([(ids[0], 0), (ids[1], 1)], actionName: wand.actionName) { i in
                seen.append((self.written(wand, m, ids[0]), self.written(wand, m, ids[1]), m.enhanceReading))
                return self.edit(wand, i)
            }
            XCTAssertEqual(seen.count, 2, "\(wand)")
            XCTAssertFalse(seen[0].first, "\(wand): nothing is written before the first frame is read")
            XCTAssertTrue(seen[1].first, "\(wand): frame 1 is written before frame 2 is read")
            XCTAssertFalse(seen[1].second, "\(wand): and frame 2 is not written yet")
            XCTAssertEqual(seen[1].reading, ids[1], "\(wand): the spinner is on frame 2 by then")
            XCTAssertTrue(written(wand, m, ids[1]), "\(wand): frame 2 is written when its read ends")
            XCTAssertNil(m.enhanceReading)
            XCTAssertFalse(m.enhanceRunning)
        }
    }

    /// (b) and (c): one Undo after a three-frame run takes all three back to the exact bytes
    /// they held before it, one Redo writes all three again, and the step before the run is
    /// neither merged in nor renamed.
    @MainActor
    func testOneUndoTakesTheWholeRunBackAndOneRedoWritesItAgain() async throws {
        for wand in Wand.allCases {
            let (m, ids) = try scratchRollModel(frames: 3, in: scratch, name: "roll-b-\(wand)")
            // a hand step first, on the stack under the run
            m.selection = [ids[2]]
            let contrast = try XCTUnwrap(EnhanceControl.all.first { $0.id == "contrast" })
            m.applyToSelection({ SidecarEdits.setEnhance($0, contrast.setting($0.enhance ?? .identity, to: 0.2)) },
                               actionName: contrast.label)
            let before = try bytes(m, ids)

            await m.runWand(ids.enumerated().map { ($1, $0) }, actionName: wand.actionName) { self.edit(wand, $0) }
            let after = try bytes(m, ids)
            for i in 0..<3 { XCTAssertNotEqual(after[i], before[i], "\(wand): frame \(i) was written") }
            XCTAssertEqual(m.undoManager.undoActionName, wand.actionName)

            m.undoManager.undo()
            XCTAssertEqual(try bytes(m, ids), before, "\(wand): one Undo restores all three, byte for byte")
            XCTAssertEqual(m.undoManager.undoActionName, contrast.label,
                           "\(wand): the step under the run is still there and keeps its name")
            XCTAssertEqual(m.undoManager.redoActionName, wand.actionName)

            m.undoManager.redo()
            XCTAssertEqual(try bytes(m, ids), after, "\(wand): one Redo writes all three again")
            XCTAssertFalse(m.undoManager.canRedo)

            m.undoManager.undo()
            XCTAssertEqual(try bytes(m, ids), before, "\(wand): and undoes again after the redo")
        }
    }

    /// A frame edited by hand while the run is still going is taken back to its PRE-RUN
    /// sidecar by the run's Undo, as `runWand` documents.
    @MainActor
    func testAFrameEditedMidRunIsRestoredToItsPreRunSidecar() async throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        let before = try bytes(m, ids)
        let contrast = try XCTUnwrap(EnhanceControl.all.first { $0.id == "contrast" })
        await m.runWand([(ids[0], 0), (ids[1], 1)], actionName: "Auto Enhance") { i in
            if i == 1 {
                m.selection = [ids[0]]
                m.applyToSelection({ SidecarEdits.setEnhance($0, contrast.setting($0.enhance ?? .identity, to: 0.3)) },
                                   actionName: contrast.label)
            }
            return self.edit(.enhance, i)
        }
        XCTAssertEqual(m.frame(ids[0])?.sidecar.enhance?.contrast, 0.3, "the hand edit landed mid-run")
        m.undoManager.undo()
        XCTAssertEqual(try bytes(m, ids), before, "the run's Undo restores both frames to before the run")
    }

    /// (d): one frame is one write and exactly one undo step, with no spinner, and the wand
    /// reads lit afterwards.
    @MainActor
    func testASingleFrameRunIsOneWriteAndOneStep() async throws {
        for wand in Wand.allCases {
            let (m, ids) = try scratchRollModel(frames: 2, in: scratch, name: "roll-d-\(wand)")
            m.selection = [ids[0]]
            XCTAssertFalse(m.undoManager.canUndo, "a fresh model has no steps")
            let before = try bytes(m, ids)
            var reading: [Frame.ID?] = []
            await m.runWand([(ids[0], 0)], actionName: wand.actionName) { i in
                reading.append(m.enhanceReading)
                XCTAssertFalse(m.enhanceRunning, "one frame shows no spinner")
                return self.edit(wand, i)
            }
            XCTAssertEqual(reading, [nil])
            XCTAssertTrue(wand == .enhance ? m.autoEnhanceLit : m.colorAutoLit, "\(wand): the wand lights")
            XCTAssertEqual(try bytes(m, ids)[1], before[1], "\(wand): the other frame is untouched")
            m.undoManager.undo()
            XCTAssertEqual(try bytes(m, ids), before, "\(wand): one Undo restores the frame")
            XCTAssertFalse(m.undoManager.canUndo, "\(wand): the run was exactly one step")
            XCTAssertFalse(wand == .enhance ? m.autoEnhanceLit : m.colorAutoLit)
        }
    }

    /// A read that returns nothing (a failed render, a frame with no color) leaves that frame
    /// alone and out of the step, and a run that wrote nothing registers no step at all.
    @MainActor
    func testAFrameWithNoResultIsLeftOutOfTheStep() async throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        let before = try bytes(m, ids)
        await m.runWand([(ids[0], 0), (ids[1], 1)], actionName: "Neutralize Cast") { _ in nil }
        XCTAssertFalse(m.undoManager.canUndo, "nothing written, no step")
        await m.runWand([(ids[0], 0), (ids[1], 1)], actionName: "Neutralize Cast") { i in
            i == 0 ? self.edit(.color, 0) : nil
        }
        XCTAssertEqual(try bytes(m, ids)[1], before[1])
        m.undoManager.undo()
        XCTAssertEqual(try bytes(m, ids), before)
        XCTAssertFalse(m.undoManager.canUndo)
    }

    /// Both wands' buttons run through `runWand`, and the wand file holds no undo group of
    /// its own, so none can be left open across an await.
    func testBothWandsRunFrameByFrame() throws {
        let s = try repoSource("Sources/FilmPositive/App/AppModel+AutoEnhance.swift")
        for entry in ["func autoEnhanceSelection()", "func neutraliseCastSelection()"] {
            let start = try XCTUnwrap(s.range(of: entry), entry)
            let rest = s[start.upperBound...]
            let body = rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]
            XCTAssertTrue(body.contains("runWand(jobs"), "\(entry) writes frame by frame")
        }
        XCTAssertFalse(s.contains("beginUndoGrouping"), "no group is opened in the wand file")
    }
}

import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Enhance Auto is a button with a state, and every Look chip follows the same four
/// transitions. Lit while the layer still holds what that button wrote, dim the moment a
/// slider moves, a click on a lit one takes the layer back to 0, and one Undo restores
/// whatever a click changed.
///
/// The wand's own solve is not under test here (`AutoEnhanceTests` owns it), so the dim to lit
/// step writes a proposal through `applyAutoEnhance`, the one path the wand's result takes.
final class AutoStateTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let proposal = AutoEnhance.Proposal(blackPoint: 0.3, brightness: 0.2, highlights: -0.1,
                                                saturation: 0.1, vibrance: 0.05)

    @MainActor
    private func slider(_ m: AppModel, _ id: Frame.ID) -> Double? {
        m.frame(id)?.sidecar.enhance?.blackPoint
    }

    /// The four transitions for Auto on one frame.
    @MainActor
    func testAutoLightsDimsClearsAndUndoes() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.selection = [ids[0]]
        XCTAssertFalse(m.autoEnhanceLit, "a fresh frame reads dim")

        // dim to lit: the wand's write records itself
        m.applyAutoEnhance([(ids[0], proposal)])
        XCTAssertTrue(m.autoEnhanceLit)
        XCTAssertEqual(m.frame(ids[0])?.sidecar.look, SidecarEdits.autoLookID)
        XCTAssertEqual(slider(m, ids[0]), 0.3)

        // lit to 0: the layer and the record both go
        m.autoEnhanceClicked()
        XCTAssertFalse(m.autoEnhanceLit)
        XCTAssertNil(m.frame(ids[0])?.sidecar.enhance, "a click on a lit Auto returns the layer to 0")
        XCTAssertNil(m.frame(ids[0])?.sidecar.look)

        // undo restores the values AND the lit state, in one step
        m.undoManager.undo()
        XCTAssertTrue(m.autoEnhanceLit, "undo brings Auto back lit")
        XCTAssertEqual(slider(m, ids[0]), 0.3)

        // a slider edit clears the record and keeps the values
        let control = try XCTUnwrap(EnhanceControl.all.first { $0.id == "contrast" })
        m.applyToSelection({ s in
            SidecarEdits.setEnhance(s, control.setting(s.enhance ?? .identity, to: 0.2))
        }, actionName: control.label)
        XCTAssertFalse(m.autoEnhanceLit, "any slider edit dims Auto")
        XCTAssertEqual(slider(m, ids[0]), 0.3, "and leaves the wand's values where they were")
        m.undoManager.undo()
        XCTAssertTrue(m.autoEnhanceLit, "undoing the slider edit lights it again")
    }

    /// Bulk: lit only while EVERY selected frame is lit, and a lit bulk click zeroes them all
    /// in one undo step.
    @MainActor
    func testAutoIsLitOnASelectionOnlyWhenEveryFrameIs() throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        m.applyAutoEnhance([(ids[0], proposal), (ids[1], proposal)])
        m.selection = [ids[0], ids[1]]
        XCTAssertTrue(m.autoEnhanceLit)
        m.selection = [ids[0], ids[1], ids[2]]
        XCTAssertFalse(m.autoEnhanceLit, "one frame the wand never read keeps it dim")

        m.selection = [ids[0], ids[1]]
        m.autoEnhanceClicked()
        XCTAssertNil(m.frame(ids[0])?.sidecar.enhance)
        XCTAssertNil(m.frame(ids[1])?.sidecar.enhance)
        m.undoManager.undo()
        XCTAssertEqual(slider(m, ids[0]), 0.3)
        XCTAssertEqual(slider(m, ids[1]), 0.3)
        XCTAssertTrue(m.autoEnhanceLit)
    }

    /// The same four transitions for a Look chip, and a Look dims Auto.
    @MainActor
    func testALookLightsDimsClearsAndUndoes() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        let look = try XCTUnwrap(ShippedLooks.all.first { !$0.settings.isIdentity })
        m.selection = [ids[0]]
        m.applyAutoEnhance([(ids[0], proposal)])
        XCTAssertFalse(m.lookLit(look))

        // dim to lit
        m.lookClicked(look)
        XCTAssertTrue(m.lookLit(look))
        XCTAssertFalse(m.autoEnhanceLit, "a Look replaces the wand's layer, so Auto dims")
        XCTAssertEqual(m.frame(ids[0])?.sidecar.enhance ?? .identity, look.settings)

        // lit to 0
        m.lookClicked(look)
        XCTAssertFalse(m.lookLit(look))
        XCTAssertNil(m.frame(ids[0])?.sidecar.enhance, "a click on a lit Look returns the layer to 0")

        // undo restores
        m.undoManager.undo()
        XCTAssertTrue(m.lookLit(look))
        XCTAssertEqual(m.frame(ids[0])?.sidecar.enhance ?? .identity, look.settings)

        // a slider edit clears it
        let control = try XCTUnwrap(EnhanceControl.all.first)
        m.applyToSelection({ s in
            SidecarEdits.setEnhance(s, control.setting(s.enhance ?? .identity, to: 0.11))
        }, actionName: control.label)
        XCTAssertFalse(m.lookLit(look), "any slider edit dims the Look")
    }

    /// Paste All from a lit frame carries the values and not the record: the wand read the
    /// source, not the target, so Auto stays dim there.
    @MainActor
    func testPastedAutoValuesDoNotLightTheTarget() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.applyAutoEnhance([(ids[0], proposal)])
        let board = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))
        m.copySettings([.enhance], from: ids[0], to: board)
        m.selection = [ids[1]]
        m.pasteSettings(from: board)
        XCTAssertEqual(slider(m, ids[1]), 0.3, "the values arrive")
        XCTAssertNil(m.frame(ids[1])?.sidecar.look)
        XCTAssertFalse(m.autoEnhanceLit)
    }

    /// No saved look can take the Auto id, because a slug keeps letters and digits only.
    func testNoSavedLookCanCollideWithTheAutoRecord() {
        XCTAssertNotEqual(LookStore.slug(SidecarEdits.autoLookID), SidecarEdits.autoLookID)
        XCTAssertNotEqual(LookStore.slug("Auto"), SidecarEdits.autoLookID)
        XCTAssertFalse(ShippedLooks.all.contains { $0.id == SidecarEdits.autoLookID })
    }
}

import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// A double-click reset is ONE undo step with the double click that asked for it.
///
/// A press on a slider track is a drag of zero distance, so the first click of a double click
/// sets the value under the pointer and closes its own undo group before the double click is
/// recognized, and the second press opens another. Without the coalescer, undo after the
/// reset returns the first click's value. These tests drive the coalescer through the exact
/// sequence a double click produces, with the inspector's own enhance edit, and read the
/// frame back.
final class DoubleClickResetUndoTests: XCTestCase {

    private var scratch: URL!
    private let exposure = EnhanceControl.all.first { $0.id == "exposure" }!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-dclick-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A model with one selected frame and a coalescer on a clock the test moves.
    @MainActor
    private final class Rig {
        let model: AppModel
        let coalescer: UndoCoalescer
        let control: EnhanceControl
        var now = Date(timeIntervalSince1970: 1_000)

        init(_ model: AppModel, control: EnhanceControl) {
            self.model = model
            self.control = control
            coalescer = UndoCoalescer(model.undoManager)
            coalescer.doubleClickInterval = 0.5
            coalescer.clock = { [unowned self] in self.now }
        }

        var value: Double {
            control.value(in: model.selectedFrames.first?.sidecar.enhance ?? .identity)
        }

        /// The inspector's enhance edit (`InspectorView.setEnhance`).
        func set(_ v: Double) {
            model.applyToSelection({ sidecar in
                let current = sidecar.enhance ?? .identity
                let updated = control.setting(current, to: v)
                guard updated != current else { return sidecar }
                return SidecarEdits.setEnhance(sidecar, updated)
            }, actionName: control.label)
        }

        func wait(_ s: TimeInterval) { now = now.addingTimeInterval(s) }

        /// One press on the track: drag start, the value under the pointer, drag end.
        func press(at v: Double, ending: Bool = true) {
            coalescer.begin(control.label)
            set(v)
            wait(0.07)
            if ending { coalescer.end() }
        }

        /// The row's reset, as the inspector wires it.
        func reset() { coalescer.reset { set(0) } }

        /// The sequence a double click at `v` produces. The tap is recognized on the second
        /// mouse up, before that press's drag ends, which is what the screen showed: the
        /// reset landed inside the second press's group.
        func doubleClick(at v: Double, resetBeforeDragEnds: Bool = true) {
            press(at: v)
            wait(0.08)
            press(at: v, ending: !resetBeforeDragEnds)
            reset()
            coalescer.end()
        }
    }

    @MainActor
    private func rig() throws -> Rig {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...2 {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        // A test has no event loop, so the automatic per-event group would never close and
        // every step would nest inside it. Off, the explicit groups are the top level ones,
        // the shape the app produces (see `UndoScopeTests.modelWithFolder`).
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        model.selection = [try XCTUnwrap(model.framesInView.first?.id)]
        // A developed frame, so no edit here also writes the develop defaults, and a clean
        // stack, so every step on it is one these tests made.
        model.applyToSelection({ s in
            var out = s
            out.develop = DevelopSettings(stock: "kodak-gold-200", autoTone: true, base: BaseSettings(mode: .anchor))
            return out
        }, actionName: "Develop", seedsDefaults: false)
        model.undoManager.removeAllActions()
        XCTAssertNotNil(model.selectedFrames.first?.sidecar.develop)
        return Rig(model, control: exposure)
    }

    @MainActor
    func testUndoAfterADoubleClickResetReturnsTheValueBeforeTheDoubleClick() throws {
        let r = try rig()
        r.press(at: 0.4)
        r.wait(3)
        r.doubleClick(at: 0.7)
        XCTAssertEqual(r.value, 0, "the double click should reset")
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.4, "one undo should return the value from before the double click, not the first click's 0.7")
        r.model.undoManager.redo()
        XCTAssertEqual(r.value, 0, "redo should reset again")
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.4)
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0, "the next undo takes back the single click before the double click")
    }

    /// The negative control: the same double click with the reset written straight to the
    /// model undoes to the first click's value. Without this the test above could pass on a
    /// sequence that never showed the defect.
    @MainActor
    func testAResetOutsideTheCoalescerUndoesToTheFirstClick() throws {
        let r = try rig()
        r.press(at: 0.4)
        r.wait(3)
        r.press(at: 0.7)
        r.wait(0.08)
        r.press(at: 0.7, ending: false)
        r.set(0)
        r.coalescer.end()
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.7, "the unwrapped reset should show the defect")
    }

    /// The same when the tap is recognized after the second press's drag has ended.
    @MainActor
    func testUndoAfterADoubleClickResetWhenTheTapFollowsTheDragEnd() throws {
        let r = try rig()
        r.press(at: -0.25)
        r.wait(3)
        r.doubleClick(at: 0.6, resetBeforeDragEnds: false)
        XCTAssertEqual(r.value, 0)
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, -0.25)
        r.model.undoManager.redo()
        XCTAssertEqual(r.value, 0)
    }

    /// A double click on a row already at rest: the first click moves it, the reset puts it
    /// back, and undo leaves it at rest instead of at the first click's value.
    @MainActor
    func testADoubleClickResetFromRestUndoesToRest() throws {
        let r = try rig()
        r.doubleClick(at: 0.5)
        XCTAssertEqual(r.value, 0)
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0, "undo returned the first click's value")
    }

    /// A lone click sets the value at once, before its drag even ends, and one undo takes
    /// it back.
    @MainActor
    func testASingleClickSetsAtOnceAndUndoesInOneStep() throws {
        let r = try rig()
        r.press(at: 0.3)
        r.wait(2)
        r.press(at: 0.55, ending: false)
        XCTAssertEqual(r.value, 0.55, "the click should set the value with no wait")
        r.coalescer.end()
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.3, "one undo should take back exactly one click")
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0)
    }

    /// The reset mark pressed right after one click is not a double click: the click stays
    /// its own step.
    @MainActor
    func testTheResetMarkAfterOneClickIsItsOwnStep() throws {
        let r = try rig()
        r.press(at: 0.45)
        r.wait(0.1)
        r.reset()
        XCTAssertEqual(r.value, 0)
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.45)
    }

    /// Two clicks further apart than the double-click interval are two clicks, and a reset
    /// after them takes back nothing but itself.
    @MainActor
    func testTwoSlowClicksThenAResetAreNotFoldedTogether() throws {
        let r = try rig()
        r.press(at: 0.2)
        r.wait(1)
        r.press(at: 0.8)
        r.wait(0.1)
        r.reset()
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.8)
        r.model.undoManager.undo()
        XCTAssertEqual(r.value, 0.2)
    }

    /// A step another control registered between the presses and the reset is never undone
    /// by the reset: the run is only taken back while the top step is the row's own.
    @MainActor
    func testAStepFromAnotherControlIsNeverTakenBack() throws {
        let r = try rig()
        r.press(at: 0.4)
        r.wait(0.1)
        r.press(at: 0.7)
        let warmth = EnhanceControl.all.first { $0.id == "warmth" }!
        r.model.undoManager.beginUndoGrouping()
        r.model.applyToSelection({ SidecarEdits.setEnhance($0, warmth.setting($0.enhance ?? .identity, to: 0.3)) },
                                 actionName: warmth.label)
        r.model.undoManager.endUndoGrouping()
        r.reset()
        let enhance = r.model.selectedFrames.first?.sidecar.enhance ?? .identity
        XCTAssertEqual(warmth.value(in: enhance), 0.3, "the reset took back another control's step")
    }
}

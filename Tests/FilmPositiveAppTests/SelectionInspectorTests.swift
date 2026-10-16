import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The inspector reads and writes the SELECTION, and says Multiple where the frames disagree.
///
/// An inspector that edits `selectedFrames.first` while the subtitle says "N selected" acts
/// on one frame of a group and nothing visible says so. Every test here is written so it
/// would FAIL against that behavior.
final class SelectionInspectorTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func modelWithFolder(count: Int = 4) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        // Same reason as UndoScopeTests: a test has no run loop event, so the automatic
        // grouping would swallow every explicit group and one undo would unwind the test.
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    /// One seeded action in its own group. `groupsByEvent` is off here (see above), so a
    /// bare `apply` would throw rather than register.
    @MainActor
    private func group(_ model: AppModel, _ body: () -> Void) {
        model.undoManager.beginUndoGrouping()
        body()
        model.undoManager.endUndoGrouping()
    }

    @MainActor
    private func develop(_ model: AppModel, _ ids: [Frame.ID], stock: String, autoTone: Bool = false) {
        for id in ids { group(model) {
            model.apply({ s in
                SidecarEdits.setDevelop(s, DevelopSettings(
                    stock: stock,
                    autoTone: autoTone,
                    base: BaseSettings(mode: .anchor, anchor: 4000, ratios: BaseRatios(rg: 0.22648, bg: 1.32673))))
            }, to: id, actionName: "seed")
        } }
    }

    @MainActor
    private func enhance(_ model: AppModel, _ id: Frame.ID, contrast: Double) {
        group(model) {
            model.apply({ s in
                var e = s.enhance ?? .identity
                e.contrast = contrast
                return SidecarEdits.setEnhance(s, e)
            }, to: id, actionName: "seed")
        }
    }

    // MARK: SharedValue, the pure rule

    func testSharedValueReadsAgreementDisagreementAndEmptiness() {
        XCTAssertEqual(SharedValue<Int>([]), .empty)
        XCTAssertEqual(SharedValue([7]), .uniform(7))
        XCTAssertEqual(SharedValue([7, 7, 7]), .uniform(7))
        XCTAssertEqual(SharedValue([7, 7, 8]), .multiple)
        // The disagreement can be anywhere, including the last element, which a loop that
        // compares neighbours pairwise and returns early gets right and a loop that only
        // checks the first pair does not.
        XCTAssertEqual(SharedValue([1, 1, 1, 1, 2]), .multiple)
        XCTAssertEqual(SharedValue([2, 1, 1, 1, 1]), .multiple)
        // Optionals: nil is a value like any other, and nil against a value disagrees.
        XCTAssertEqual(SharedValue<String?>([nil, nil]), .uniform(nil))
        XCTAssertEqual(SharedValue<String?>([nil, "a"]), .multiple)
        // `value` deliberately answers nil for BOTH empty and multiple: the question it
        // answers is "what should I display", and neither has an answer.
        XCTAssertNil(SharedValue<Int>([]).value)
        XCTAssertNil(SharedValue([1, 2]).value)
        XCTAssertEqual(SharedValue([1, 1]).value, 1)
        XCTAssertTrue(SharedValue([1, 2]).isMultiple)
        XCTAssertFalse(SharedValue([1, 1]).isMultiple)
        XCTAssertFalse(SharedValue<Int>([]).isMultiple, "empty is not a disagreement")
    }

    // MARK: the summary the inspector reads

    @MainActor
    func testSummaryReportsSharedValuesAndMultiple() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, ids, stock: "kodak-portra-400")
        enhance(model, ids[0], contrast: 0.5)
        enhance(model, ids[1], contrast: 0.5)
        enhance(model, ids[2], contrast: 0.5)
        enhance(model, ids[3], contrast: -0.2)

        model.selection = Set(ids.prefix(3))
        var summary = model.selectionSummary
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.developedCount, 3)
        XCTAssertEqual(summary.stock.value, "kodak-portra-400")
        XCTAssertEqual(summary.value(for: contrastControl).value, 0.5)
        XCTAssertFalse(summary.value(for: contrastControl).isMultiple)

        model.selection = Set(ids)
        summary = model.selectionSummary
        XCTAssertEqual(summary.count, 4)
        XCTAssertTrue(summary.value(for: contrastControl).isMultiple, "one frame differs")
        XCTAssertEqual(summary.stock.value, "kodak-portra-400", "they still agree about the stock")
        // A control nobody touched still agrees, at the identity value.
        XCTAssertEqual(summary.value(for: saturationControl).value, 0)
        // The slider parks at identity while mixed rather than at any one frame's value.
        XCTAssertEqual(summary.sliderPosition(contrastControl), 0)
    }

    @MainActor
    func testDevelopValuesAreReadOverEffectiveDevelop() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, Array(ids.prefix(2)), stock: "kodak-portra-400")
        model.selection = Set(ids)

        let summary = model.selectionSummary
        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.developedCount, 2)
        XCTAssertEqual(summary.undevelopedCount, 2)
        XCTAssertTrue(summary.hasDevelop)
        // The rows read EFFECTIVE develop, so the two undeveloped frames report the defaults
        // they are being rendered through rather than being skipped. Those defaults resolve
        // to the generic stock here and the two developed frames say portra, so the selection
        // disagrees and Multiple is the honest answer.
        XCTAssertTrue(summary.stock.isMultiple,
                      "two frames on portra and two on the default stock disagree")
        XCTAssertNil(summary.stock.value)

        // And a selection where every frame agrees reads as uniform even though half of it
        // is undeveloped, which is the case the inspector actually has to draw: a fresh
        // roll where nothing is written.
        let fresh = try modelWithFolder()
        fresh.0.selection = Set(fresh.1)
        let all = fresh.0.selectionSummary
        XCTAssertEqual(all.developedCount, 0, "nothing written")
        XCTAssertEqual(all.stock.value, ProfileLibrary.genericStockName,
                       "every frame shows the default stock, so the picker shows it too")
        XCTAssertEqual(all.tone.value, ToneMode.none, "and the default tone")
        // The lines that describe a frame's state say "developed": Develop is what you do, a
        // Positive is what you get.
        XCTAssertEqual(summary.subtitle, "2 not yet developed")
        XCTAssertEqual(summary.title(single: "IMG_0001.CR2"), "4 Frames")

        // Nothing developed at all is a different sentence, and the develop section hides.
        model.selection = Set(ids.suffix(2))
        let none = model.selectionSummary
        XCTAssertFalse(none.hasDevelop)
        XCTAssertEqual(none.subtitle, "none developed yet")
    }

    @MainActor
    func testOneFrameSelectedHasNoSubtitleAndKeepsItsName() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, [ids[0]], stock: "kodak-gold-200")
        model.selection = [ids[0]]
        let summary = model.selectionSummary
        XCTAssertEqual(summary.title(single: "IMG_0001.CR2"), "IMG_0001.CR2")
        XCTAssertEqual(summary.subtitle, "", "one frame needs no count")
    }

    // MARK: writing the whole selection

    @MainActor
    func testAnEnhanceEditReachesEverySelectedFrame() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = Set(ids)
        model.applyToSelection({ s in
            var e = s.enhance ?? .identity
            e.contrast = 0.4
            return SidecarEdits.setEnhance(s, e)
        }, actionName: "Contrast")

        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.contrast, 0.4,
                           "every selected frame, not the first one")
        }
    }

    @MainActor
    func testASelectionEditIsOneUndoStep() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = Set(ids)
        model.undoManager.removeAllActions()
        model.applyToSelection({ s in
            var e = s.enhance ?? .identity
            e.contrast = 0.4
            return SidecarEdits.setEnhance(s, e)
        }, actionName: "Contrast")
        XCTAssertTrue(model.undoManager.canUndo)

        model.undoManager.undo()

        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.contrast ?? 0, 0,
                           "one Command Z unwinds the whole selection edit, not one frame of it")
        }
        XCTAssertFalse(model.undoManager.canUndo, "and there is nothing left behind it")

        model.undoManager.redo()
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.contrast, 0.4, "redo puts all of them back")
        }
    }

    @MainActor
    func testDevelopOnlyControlsSkipUndevelopedFramesAndLeaveThemAlone() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, Array(ids.prefix(2)), stock: "kodak-portra-400")
        model.selection = Set(ids)

        model.applyToSelection({ s in
            guard var d = s.develop else { return s }
            d.stock = "kodak-ektar-100"
            return SidecarEdits.setDevelop(s, d)
        }, actionName: "Film Stock", where: \.isDeveloped)

        XCTAssertEqual(model.frame(ids[0])?.sidecar.develop?.stock, "kodak-ektar-100")
        XCTAssertEqual(model.frame(ids[1])?.sidecar.develop?.stock, "kodak-ektar-100")
        XCTAssertNil(model.frame(ids[2])?.sidecar.develop, "an undeveloped frame stays undeveloped")
        XCTAssertNil(model.frame(ids[3])?.sidecar.develop,
                     "the stock write must not invent a develop layer for a frame that has none")
    }

    @MainActor
    func testAnEditWithNothingSelectedDoesNothing() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = []
        model.applyToSelection({ s in
            var e = s.enhance ?? .identity
            e.contrast = 0.9
            return SidecarEdits.setEnhance(s, e)
        }, actionName: "Contrast")
        XCTAssertFalse(model.undoManager.canUndo, "an empty selection registers no undo step")
        for id in ids { XCTAssertNil(model.frame(id)?.sidecar.enhance) }
    }

    @MainActor
    func testResetsAndLooksReachTheWholeSelection() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, ids, stock: "kodak-portra-400")
        for id in ids { enhance(model, id, contrast: 0.3) }
        model.selection = Set(ids)

        model.resetEnhanceSelection()
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.contrast ?? 0, 0, "reset enhance is selection wide")
        }

        let look = Look(id: "arcade", name: "Arcade", blurb: "loud",
                        settings: EnhanceSettings(contrast: 0.25, saturation: 0.35), shipped: true)
        model.applyToSelection({ SidecarEdits.applyLook($0, look) }, actionName: "Apply Arcade")
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.look, "arcade", "a look is one tap for the whole selection")
        }
        XCTAssertEqual(model.selectionSummary.look.value, "arcade")

        model.resetDevelopSelection()
        for id in ids { XCTAssertNil(model.frame(id)?.sidecar.develop, "reset develop is selection wide") }
    }

    @MainActor
    func testTheMixedTagIsNeverAStockAndNeverWritten() throws {
        // The placeholder a picker carries while the frames disagree must not collide with
        // anything the library can offer, or choosing a real stock would be ambiguous.
        let choices = StockChoices.list(from: nil, current: nil)
        XCTAssertFalse(choices.contains { $0.id == SelectionSummary.mixedTag })
        XCTAssertTrue(SelectionSummary.mixedTag.contains("."), "namespaced, so it cannot be a slug")
    }

    // MARK: the Positive action

    /// Choosing a Stock on a selection of negatives gives each frame a develop layer with the
    /// chosen stock, and the whole thing is ONE undo step.
    ///
    /// The Stock picker's edit goes through `applyToSelection`, and the funnel in
    /// `AppModel.apply` seeds the defaults beside the chosen value, which is what makes the
    /// pair a single undo.
    @MainActor
    func testChoosingAStockOnASelectionOfNegativesCommitsInOneUndoStep() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = Set(ids)
        // The bundled library resolves even under `FailingRenderService`, because
        // `renders.profiles` falls back to `ProfileLibrary.bundled()`.
        try XCTSkipIf(model.renders.profiles == nil, "no bundled profiles on this host")
        for id in ids { XCTAssertNil(model.frame(id)?.sidecar.develop, "they start as negatives") }

        group(model) {
            model.applyToSelection({ sidecar in
                guard var d = sidecar.develop else { return sidecar }
                d.stock = "kodak-ektar-100"
                return SidecarEdits.setDevelop(sidecar, d)
            }, actionName: "Stock")
        }
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.develop?.stock, "kodak-ektar-100",
                           "a negative gets a develop layer with the chosen stock")
        }
        XCTAssertTrue(model.undoManager.canUndo)
        model.undoManager.undo()
        for id in ids { XCTAssertNil(model.frame(id)?.sidecar.develop, "and the whole action is one undo") }
    }

    /// A re-run that changes one field must not wipe the others.
    @MainActor
    func testARerunWritesOnlyTheFieldsItWasGiven() throws {
        let (model, ids) = try modelWithFolder()
        develop(model, ids, stock: "kodak-portra-400")
        let look = Look(id: "arcade", name: "Arcade", blurb: "loud",
                        settings: EnhanceSettings(contrast: 0.25, saturation: 0.35), shipped: true)
        model.selection = Set(ids)
        group(model) { model.applyToSelection({ SidecarEdits.applyLook($0, look) }, actionName: "Apply Arcade") }
        for id in ids { XCTAssertEqual(model.frame(id)?.sidecar.look, "arcade") }

        // The re-run: change the stock only.
        group(model) {
            model.applyToSelection({ sidecar in
                guard var d = sidecar.develop else { return sidecar }
                d.stock = "kodak-ektar-100"
                return SidecarEdits.setDevelop(sidecar, d)
            }, actionName: "Film Stock", where: \.isDeveloped)
        }
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.develop?.stock, "kodak-ektar-100", "the field that was given")
            XCTAssertEqual(model.frame(id)?.sidecar.look, "arcade", "the fields that were not")
        }
    }

    // MARK: what a cell draws while a render is in flight

    @MainActor
    func testAFrameKeepsItsLastPositiveInsteadOfFallingBackToTheNegative() throws {
        let (model, ids) = try modelWithFolder()
        let undeveloped = model.frame(ids[0])!
        // An undeveloped frame is a NEGATIVE and is not waiting for anything, so it
        // draws the negative thumbnail at full strength with no spinner.
        XCTAssertEqual(FrameCellState.of(frame: undeveloped, hasImage: false), .negative)
        XCTAssertEqual(FrameCellState.of(frame: undeveloped, hasImage: true), .negative,
                       "no develop layer means no positive, whatever happens to be cached")

        develop(model, [ids[0]], stock: "kodak-portra-400")
        let developed = model.frame(ids[0])!

        // Never rendered: the negative is the only thing there is to draw.
        XCTAssertEqual(FrameCellState.of(frame: developed, hasImage: false), .rendering)
        // Rendered and current.
        XCTAssertEqual(FrameCellState.of(frame: developed, hasImage: true, isStale: false), .positive)
        // Rendered, then edited. Falling through to the negative here would make the picture
        // jump back to an orange negative and then return, which reads as the frame being
        // reset rather than updated.
        XCTAssertEqual(FrameCellState.of(frame: developed, hasImage: true, isStale: true), .restaging)

        // Both positive states draw the positive; both working states show a spinner.
        XCTAssertTrue(FrameCellState.positive.showsPositive)
        XCTAssertTrue(FrameCellState.restaging.showsPositive)
        XCTAssertFalse(FrameCellState.rendering.showsPositive)
        XCTAssertTrue(FrameCellState.restaging.isWorking)
        XCTAssertTrue(FrameCellState.rendering.isWorking)
        XCTAssertFalse(FrameCellState.positive.isWorking)
        // The negative is neither: no positive to draw, and nothing in flight to spin for.
        XCTAssertFalse(FrameCellState.negative.showsPositive)
        XCTAssertFalse(FrameCellState.negative.isWorking)

        // Resetting develop sends the cell back to the negative: with no develop layer there
        // is no positive, cached image or not.
        model.selection = [ids[0]]
        model.resetDevelopSelection()
        XCTAssertEqual(FrameCellState.of(frame: model.frame(ids[0])!, hasImage: true, isStale: false), .negative)
    }

    // MARK: control lookups used above

    private var contrastControl: EnhanceControl {
        EnhanceControl.all.first { $0.id == "contrast" }!
    }
    private var saturationControl: EnhanceControl {
        EnhanceControl.all.first { $0.id == "saturation" }!
    }
}

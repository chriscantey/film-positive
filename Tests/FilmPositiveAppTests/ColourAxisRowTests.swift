import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The two color axis rows: where they are drawn, what they write, and the two ways a
/// perfectly plausible implementation of them would quietly destroy data.
///
/// WHAT THIS SUITE CANNOT PROVE. Every rule here is asserted off a pure function or off the
/// model, never off a rendered view, so nothing below proves that `InspectorView` actually
/// CALLS any of it, that the rows land between Auto color and Tone on screen, or that the label
/// column fits at the inspector's 330 pt minimum. Those are screen checks. What this suite
/// does prove is that the rules the view calls are right, which is the half that can rot
/// silently: a misplaced row is visible the moment anyone looks, and an axis quietly zeroing
/// its neighbour across a forty frame selection is not.
final class ColourAxisRowTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-colour-axis-row-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: harness

    /// A model over `count` frames that carry NO sidecar, which is the state a freshly
    /// copied roll is in and the state the funnel rule is about.
    ///
    /// The real profile library, because the defaults resolve a capture film name through it
    /// and a stand-in would make the funnel row below assert against nil.
    @MainActor
    private func freshModel(count: Int = 3) throws -> (AppModel, [Frame.ID], URL) {
        let roll = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        // A test has no run loop event, so automatic grouping would swallow every explicit
        // group and one undo would unwind the whole test.
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(roll))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids, roll)
    }

    /// Gives a frame a develop layer with the axes already at `axes`, as a seed rather than
    /// as the thing under test.
    @MainActor
    private func seedDevelop(_ model: AppModel, _ id: Frame.ID, axes: ColourAxes = .identity) {
        model.undoManager.beginUndoGrouping()
        model.apply({ s in
            var develop = DevelopSettings(stock: "kodak-gold-200",
                                          tone: .none, autoBalance: true,
                                          base: BaseSettings(mode: .anchor))
            develop.colourAxes = axes
            return SidecarEdits.setDevelop(s, develop)
        }, to: id, actionName: "seed")
        model.undoManager.endUndoGrouping()
    }

    /// The edit a row makes, over the whole selection, exactly as `InspectorView
    /// .setColourAxis` issues it.
    @MainActor
    private func move(_ model: AppModel, _ axis: ColourAxis, to value: Double) {
        model.applyToSelection({ axis.edit($0, to: value) },
                               actionName: InspectorView.colourAxesAction)
    }

    @MainActor
    private func axes(_ model: AppModel, _ id: Frame.ID) -> ColourAxes? {
        model.frame(id)?.sidecar.develop?.colourAxes
    }

    // MARK: where the rows are drawn

    /// Both rows are in the set, IN ORDER, in every state of the Base control.
    ///
    /// Order rather than membership, because a SwiftUI `if` reorders nothing but a refactor
    /// can, and the whole reason the rows sit where they do is that reading the section top
    /// to bottom reads the pipeline in order: the base is resolved, the axes move it, Tone
    /// happens to the result.
    func testBothAxisRowsAreDrawnInOrderWhicheverWayAutoColorIsSet() {
        let on = PositiveRows.visibleRows(autoColor: .uniform(true))
        XCTAssertEqual(on, [.stock, .autoColor, .warmAxis, .greenAxis, .tone])

        let off = PositiveRows.visibleRows(autoColor: .uniform(false))
        XCTAssertEqual(off, [.stock, .autoColor, .warmAxis, .greenAxis, .tone])

        // The rows sit AFTER whatever settles the base and BEFORE Tone, in both sets. Stated
        // as index arithmetic so it fails on a reorder rather than only on a deletion.
        for rows in [on, off] {
            guard let warm = rows.firstIndex(of: .warmAxis),
                  let green = rows.firstIndex(of: .greenAxis),
                  let autoColor = rows.firstIndex(of: .autoColor),
                  let tone = rows.firstIndex(of: .tone)
            else { return XCTFail("a row is missing from \(rows)") }
            XCTAssertGreaterThan(warm, autoColor, "the axes come after the rows that resolve the base")
            XCTAssertEqual(green, warm + 1, "green follows warm with nothing between them")
            XCTAssertLessThan(green, tone, "and both come before Tone")
        }
    }

    /// Auto color does not govern the axes. It is easy to get wrong by analogy: both are
    /// color, so both look like they belong to the toggle. They do not. The toggle decides
    /// WHERE the base came from and the axes are a manual delta on whatever base was
    /// resolved, by either route.
    func testAutoColorDoesNotGovernTheAxes() {
        let on = Set(PositiveRows.visibleRows(autoColor: .uniform(true)))
        let off = Set(PositiveRows.visibleRows(autoColor: .uniform(false)))
        for set in [on, off] {
            XCTAssertTrue(set.contains(.warmAxis))
            XCTAssertTrue(set.contains(.greenAxis))
        }
    }

    /// A mono selection draws NEITHER axis row, in every state of the toggle.
    ///
    /// Not a tidiness judgment. `DevelopMath.base` ignores the ratios entirely when `mono`
    /// is set, so the axes cannot move a black and white frame by any amount, which
    /// `ColourAxisTests.testTheAxesAreInertOnAMonochromeFrame` proves against the kernel. A
    /// control with no possible effect should not be drawn.
    func testAMonoSelectionDrawsNeitherAxisRow() {
        for state: SharedValue<Bool?> in [.uniform(true), .uniform(false), .uniform(nil), .multiple] {
            let rows = PositiveRows.visibleRows(autoColor: state, mono: true)
            XCTAssertEqual(rows, [.stock, .autoColor, .tone], "mono rows for \(state)")
            XCTAssertFalse(rows.contains(.warmAxis))
            XCTAssertFalse(rows.contains(.greenAxis))
        }
        // And `mono` is the WHOLE of the difference: the color answer at the same state
        // still carries both. Without this the test above would pass against a function that
        // had simply dropped the rows everywhere.
        XCTAssertTrue(PositiveRows.visibleRows(autoColor: .uniform(true), mono: false)
            .contains(.warmAxis))
    }

    // MARK: what the rows write

    /// The edit reaches `develop.colourAxes` through `SidecarEdits.setColourAxes`, on every
    /// frame of the selection rather than on the lead one.
    @MainActor
    func testMovingARowWritesThroughSetColourAxesToEveryFrameInTheSelection() throws {
        let (model, ids, _) = try freshModel()
        for id in ids { seedDevelop(model, id) }
        model.selection = Set(ids)

        move(model, .warm, to: 6)
        for id in ids {
            XCTAssertEqual(axes(model, id)?.warm, 6, "every selected frame took the value")
        }

        move(model, .green, to: -3.5)
        for id in ids {
            XCTAssertEqual(axes(model, id), ColourAxes(warm: 6, green: -3.5))
        }
    }

    /// ANTI-TEST, and the reason this file exists.
    ///
    /// Moving one row writes NOTHING to the other axis, INCLUDING when the selected frames
    /// disagree about the axis nobody is touching. `SidecarEdits.setColourAxes` takes the
    /// pair, so the obvious implementation builds one `ColourAxes` from the summary and hands
    /// it to every frame. That flattens the untouched axis to the lead frame's value, or to
    /// zero on a Multiple, and on a single frame at rest it is completely invisible: both
    /// axes are zero, so writing zero over zero looks exactly like leaving it alone.
    ///
    /// Three frames with three different greens is what makes the failure visible.
    @MainActor
    func testMovingOneRowWritesNothingToTheOtherAxisEvenWhenTheFramesDisagreeAboutIt() throws {
        let (model, ids, _) = try freshModel()
        let greens = [-4.0, 0.0, 7.5]
        for (id, green) in zip(ids, greens) { seedDevelop(model, id, axes: ColourAxes(green: green)) }
        model.selection = Set(ids)

        // Precondition: the green row IS Multiple here, which is the state that breaks the
        // flattening implementation. Assert it rather than assuming it, or a change to how
        // the summary reads disagreement would make this test pass for the wrong reason.
        XCTAssertTrue(model.selectionSummary.greenAxis.isMultiple)

        move(model, .warm, to: 9)

        for (id, green) in zip(ids, greens) {
            XCTAssertEqual(axes(model, id)?.warm, 9, "the warm axis took the edit")
            XCTAssertEqual(axes(model, id)?.green, green,
                           "the green axis this frame already had must be untouched")
        }
        XCTAssertTrue(model.selectionSummary.greenAxis.isMultiple,
                      "and the selection still disagrees about green, so nothing was flattened")
    }

    /// The funnel: a grade on an UNDEVELOPED frame commits the whole default
    /// develop layer under it.
    ///
    /// A color grade with no stock beneath it would be a grade OF nothing,
    /// and the next launch would render a different frame than the one that was on screen
    /// when the user reached for the row. `DefaultsCommitTests` already walks `setColourAxes`
    /// as an entry point; this asserts the same property through the path the ROW takes,
    /// which is the one that reads the frame's own axes first and so has a real chance of
    /// returning the sidecar unchanged.
    @MainActor
    func testAGradeOnAnUndevelopedFrameCommitsTheDefaultLayerUnderIt() throws {
        let (model, ids, _) = try freshModel(count: 1)
        let id = ids[0]
        XCTAssertNil(model.frame(id)?.sidecar.develop, "the frame starts with no develop layer")
        let defaults = try XCTUnwrap(model.renders.defaults.initial(for: XCTUnwrap(model.frame(id)).sidecar),
                                     "the defaults must resolve, or this test proves nothing")

        model.selection = [id]
        move(model, .warm, to: 4)

        let develop = try XCTUnwrap(model.frame(id)?.sidecar.develop)
        XCTAssertEqual(develop.colourAxes, ColourAxes(warm: 4), "the grade landed")
        XCTAssertEqual(develop.stock, defaults.stock, "and the default stock came with it")
        XCTAssertEqual(develop.tone, defaults.tone, "and the default tone")
        XCTAssertEqual(develop.autoBalance, defaults.autoBalance, "and autoBalance")
        XCTAssertEqual(develop.base.mode, defaults.base.mode, "and the base did NOT move")
    }

    /// A mixed selection reads the way its neighbours do: the readout says Multiple, the
    /// track parks at the identity position, and an edit from there writes an ABSOLUTE value
    /// to every frame.
    ///
    /// Parking at zero rather than at one frame's value is the same rule `sliderPosition`
    /// states for an enhance slider: the row is showing "no shared value", and the identity
    /// position is the only one that does not claim a frame is the representative one.
    @MainActor
    func testAMixedSelectionSaysMultipleParksAtZeroAndWritesAbsolutely() throws {
        let (model, ids, _) = try freshModel()
        for (i, id) in ids.enumerated() { seedDevelop(model, id, axes: ColourAxes(warm: Double(i) * 5)) }
        model.selection = Set(ids)

        let summary = model.selectionSummary
        XCTAssertTrue(summary.warmAxis.isMultiple, "the frames disagree, so the row says Multiple")
        XCTAssertEqual(summary.trackPosition(.warm), 0, "and the track parks at the identity position")
        // The other row agrees, so Multiple on one axis never leaks onto the other. This is
        // why the summary asks the two axes separately.
        XCTAssertEqual(summary.greenAxis, .uniform(0))
        XCTAssertFalse(summary.greenAxis.isMultiple)

        move(model, .warm, to: 2)
        for id in ids {
            XCTAssertEqual(axes(model, id)?.warm, 2,
                           "an edit from Multiple is absolute, not a relative nudge per frame")
        }
    }

    /// Undo unwinds a selection-wide grade as ONE step, under one name.
    @MainActor
    func testTheWholeSelectionUndoesAsOneStepNamedColourAxes() throws {
        let (model, ids, _) = try freshModel()
        for id in ids { seedDevelop(model, id) }
        model.selection = Set(ids)

        move(model, .warm, to: 8)
        XCTAssertEqual(model.undoManager.undoActionName, InspectorView.colourAxesAction)

        model.undoManager.undo()
        for id in ids {
            XCTAssertEqual(axes(model, id)?.warm, 0, "one undo cleared the grade on every frame")
        }
    }

    // MARK: the numbers

    /// The resting span is plus or minus twelve points, and a value outside it WIDENS the
    /// track rather than being clipped to it.
    ///
    /// The widening rule is the same one an enhance row has: the number is taken and the
    /// track is redrawn around it, so the fill stays readable instead of the value being
    /// pinned to the end of a track it has outgrown. Twelve is a default zoom, not a limit.
    func testTheRestingSpanIsTwelvePointsAndATypedValueWidensItRatherThanBeingClipped() {
        XCTAssertEqual(ColourAxis.restingSpan, 12)

        // Exactly the computation `ColourAxisRow.effectiveRange` performs. Duplicated on
        // purpose: the row's copy is inside a View and cannot be reached without a window,
        // and a rule stated in two places that disagree is caught by the screen check.
        func span(_ value: Double) -> ClosedRange<Double> {
            let bound = max(ColourAxis.restingSpan, abs(value).rounded(.up))
            return -bound...bound
        }

        XCTAssertEqual(span(0), -12...12, "at rest")
        XCTAssertEqual(span(7), -12...12, "a real world cast of about seven points fits inside it")
        XCTAssertEqual(span(-12), -12...12, "the bound itself does not widen anything")
        XCTAssertEqual(span(13.5), -14...14, "past the bound, out to the next whole point")
        XCTAssertEqual(span(-50), -50...50, "a lab's full scale, still symmetric")

        // The anti-claim: the value is KEPT, never clipped back to twelve. A clamping
        // implementation passes every span assertion above and fails this one.
        for typed in [13.5, -13.5, 50.0, -50.0, 199.0] {
            XCTAssertEqual(ColourAxis.warm.setting(.identity, to: typed).warm, typed,
                           "a typed \(typed) must survive")
        }
    }

    /// The storage guard is not the resting span wearing a disguise. It exists so that a
    /// parse of "1e400" cannot reach the kernel as an infinite density, and nobody meets it
    /// by typing a number they meant.
    func testTheStorageGuardIsFarOutsideAnythingAPersonWouldTypeAndDropsNonFinite() {
        XCTAssertGreaterThan(ColourAxis.storageLimit.upperBound, ColourAxis.restingSpan * 4)
        XCTAssertEqual(ColourAxis.warm.setting(.identity, to: 1e9).warm,
                       ColourAxis.storageLimit.upperBound)
        // Non-finite is DROPPED rather than clamped: a NaN compares false against everything,
        // so clamping it would leave a NaN in the sidecar that every no-op guard downstream
        // reads as a change.
        XCTAssertEqual(ColourAxis.warm.setting(ColourAxes(warm: 3), to: .nan).warm, 3)
        XCTAssertEqual(ColourAxis.green.setting(ColourAxes(green: 3), to: .infinity).green, 3)
    }

    /// One arrow press is ONE PRINTER POINT and shift is a tenth of one. THERE IS NO THIRD
    /// STEP, on this row or on any other.
    ///
    /// One control behaving differently from every other control in the same panel is an
    /// inconsistency, the same kind as shift meaning opposite things on a drag and on an
    /// arrow.
    ///
    /// Driven through `CentreOriginTrack.step`, which is the function the key handler calls,
    /// rather than by multiplying the constants out here. Reading the constants back would
    /// pass against an implementation that applied a factor to the wrong modifier, because
    /// the numbers would still be present and correct.
    func testAnArrowIsOnePointShiftIsATenthAndNoOtherKeyDoesAnything() {
        func step(_ m: NSEvent.ModifierFlags) -> Double {
            CentreOriginTrack.step(ColourAxis.keyStep, modifiers: m)
        }

        XCTAssertEqual(step([]), 1, "a point is the natural quantum: it is what a lab quotes")
        XCTAssertEqual(step(.shift), 0.1, accuracy: 1e-12, "shift is fine, a tenth of a point")
        // Control is an ordinary press, the same as every other unwired modifier.
        XCTAssertEqual(step(.control), 1, "control must no longer be a coarse step")
        XCTAssertEqual(step([.shift, .control]), 0.1, accuracy: 1e-12)
        // Option is the range opener on this control and must not also become a multiplier.
        XCTAssertEqual(step(.option), 1)
        XCTAssertEqual(step(.command), 1)
        XCTAssertEqual(step([.control, .option, .command]), 1,
                       "no combination of unwired modifiers may resurrect a coarse step")

        // A plain press has somewhere to go on the shown track, which is what makes one
        // point the right quantum here rather than a slam.
        XCTAssertGreaterThan(ColourAxis.restingSpan / step([]), 2,
                             "a press that reaches the edge in one is not a step, it is a jump")

        // And the fine step is visible in the readout, which is the difference from an
        // enhance row. One decimal, so a single shift press moves the digits.
        XCTAssertEqual(String(format: "%.1f", step(.shift)), "0.1")
    }

    /// ANTI-TEST: an ENHANCE track and the axis rows read the SAME mapping rather than
    /// differing by one key.
    ///
    /// The axis rows above and this row are the same three assertions with a different
    /// quantum, which is what "one control behaves like every other control" looks like when
    /// it is written down.
    func testAnEnhanceTrackStepsExactlyAsItDidAndControlDoesNothingThereEither() {
        func step(_ m: NSEvent.ModifierFlags) -> Double {
            CentreOriginTrack.step(CentreOriginTrack.defaultKeyStep, modifiers: m)
        }
        XCTAssertEqual(step([]), 0.01)
        XCTAssertEqual(step(.control), 0.01, "control must not step an enhance slider")
        XCTAssertEqual(step([.shift, .control]), 0.001, accuracy: 1e-12,
                       "and shift is still fine there, unchanged")

        // The ratio between a plain press and a fine press is the one thing both rows share
        // exactly. If a future change gives one row a modifier the other lacks, this fails.
        let axis = { CentreOriginTrack.step(ColourAxis.keyStep, modifiers: $0) }
        XCTAssertEqual(step(.shift) / step([]), axis(.shift) / axis([]), accuracy: 1e-12,
                       "the two rows must answer the same keys in the same proportions")
    }

    /// ANTI-TEST: NO control in this app has a coarse arrow step, and there is no parameter
    /// through which one could be given to a single row.
    ///
    /// The parameter is gone rather than defaulted, and what this proves is an absence in
    /// the TRACK, which is the one place a step could be reintroduced for everyone or for one
    /// row.
    ///
    /// A source scan rather than a constructed view, because `CentreOriginTrack` cannot be
    /// built outside a body: its focus binding is a property wrapper that only resolves
    /// there. The scan carries a canary for the same reason every scan here does.
    func testNoControlInTheAppHasACoarseArrowStep() throws {
        XCTAssertEqual(CentreOriginTrack.defaultKeyStep, 0.01,
                       "the enhance step is unchanged at one unit of the readout")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let row = root.appendingPathComponent("Sources/FilmPositive/UI/Inspector/EnhanceSliderRow.swift")
        let code = ToneNamesTests.strippingComments(try String(contentsOf: row, encoding: .utf8))
        // Canary first: the scan has to be able to find something known to be in this file,
        // or "no matches" is a statement about the reader rather than about the code.
        XCTAssertTrue(code.contains("CentreOriginTrack("), "the scan did not find the track: wrong path?")
        XCTAssertFalse(code.contains("keyStep"),
                       "the enhance row must not override the arrow step")
        // And the coarse arrow step is gone from the whole app, not merely unused here.
        // Asserted against the TRACK, which is the one place a step could be reintroduced.
        let track = root.appendingPathComponent("Sources/FilmPositive/UI/Inspector/CentreOriginTrack.swift")
        let trackCode = ToneNamesTests.strippingComments(try String(contentsOf: track, encoding: .utf8))
        XCTAssertTrue(trackCode.contains("static func step("), "canary: the step function moved")
        XCTAssertFalse(trackCode.contains("coarseArrowMultiplier"),
                       "the coarse arrow parameter is back: every slider must read the same")
        XCTAssertFalse(trackCode.contains(".control"),
                       "control must reach no branch of the step mapping")
    }

    // MARK: the names

    /// The labels, and the two names they are forbidden to use.
    ///
    /// The forbidden half is the real assertion. "Warmth" and "Tint" are already the names of
    /// two ENHANCE sliders that follow a blackbody locus over the finished positive, and
    /// these are a red and blue opponent in density space applied to the base with green
    /// held. Two controls sharing a name while doing different things is what makes a panel
    /// unpredictable, and the collision is one careless rename away at any time.
    func testTheRowsAreLabelledByBothEndsAndNeverBorrowAnEnhanceSlidersName() {
        XCTAssertEqual(ColourAxis.warm.lowLabel, "Cool")
        XCTAssertEqual(ColourAxis.warm.highLabel, "Warm")
        XCTAssertEqual(ColourAxis.green.lowLabel, "Green")
        XCTAssertEqual(ColourAxis.green.highLabel, "Magenta")

        let taken = Set(EnhanceControl.all.map(\.label))
        for axis in ColourAxis.allCases {
            XCTAssertFalse(taken.contains(axis.lowLabel), "\(axis.lowLabel) is an enhance slider's name")
            XCTAssertFalse(taken.contains(axis.highLabel), "\(axis.highLabel) is an enhance slider's name")
            XCTAssertFalse(taken.contains(axis.label))
            // Both ends are named, so neither can read as a negative amount of the other.
            XCTAssertTrue(axis.label.contains(axis.lowLabel))
            XCTAssertTrue(axis.label.contains(axis.highLabel))
            // Spoken, the arrow is a word. VoiceOver reads the accessibility label.
            XCTAssertFalse(axis.accessibilityLabel.contains("\u{2194}"))
        }

        // The specific pair forbidden here, stated by name so the reason survives a
        // refactor that renames the enhance sliders out from under this scan.
        XCTAssertTrue(taken.contains("Warmth"))
        XCTAssertTrue(taken.contains("Tint"))
    }

    /// The polarity, which is the thing a label can be right about and a sign can be wrong
    /// about. Positive is toward the HIGH label on both rows.
    func testPositiveIsTowardTheHighLabelOnBothAxes() {
        // Warm: positive raises red and lowers blue by the same density, and green is
        // exactly zero. That zero is what the whole design rests on.
        let warm = ColourAxes(warm: 4).logOffsets
        XCTAssertGreaterThan(warm.r, 0, "positive warm is warmer: red up")
        XCTAssertLessThan(warm.b, 0, "and blue down")
        XCTAssertEqual(warm.g, 0, "green is held exactly")

        // Green axis: positive is toward MAGENTA, which is red and blue up together against
        // green. A sign flip here would make the row labeled Green do magenta.
        let magenta = ColourAxes(green: 4).logOffsets
        XCTAssertGreaterThan(magenta.r, 0)
        XCTAssertGreaterThan(magenta.b, 0)
        XCTAssertEqual(magenta.g, 0, "green is held on this axis too, which is why it is not called Yellow")
    }
}

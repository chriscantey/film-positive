import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The two Develop color axis rows fold into the Base row behind a fold that is closed by
/// default and remembered app-wide. The fold alone decides whether they show: a closed row
/// with an offset hides its sliders and reads lit. The fold never writes a sidecar.
final class ColourAxesFoldTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: the rule

    /// Every state of the three inputs. The fold decides and mono keeps them folded whatever
    /// the fold says. In use opens nothing: it is a column here so the table proves the rows
    /// read the same with an offset as without one, while the lit title says which it is.
    func testTheRowsShowForEveryState() {
        let cases: [(String, Bool, Bool, Bool, Bool)] = [
            // name, open, inUse, mono, shown
            ("open, zero axes", true, false, false, true),
            ("closed, zero axes", false, false, false, false),
            ("closed, a non-zero axis", false, true, false, false),
            ("open, a non-zero axis", true, true, false, true),
            ("mono, open, zero axes", true, false, true, false),
            ("mono, closed, zero axes", false, false, true, false),
            ("mono, closed, a non-zero axis", false, true, true, false),
            ("mono, open, a non-zero axis", true, true, true, false),
        ]
        XCTAssertEqual(cases.count, 8, "every state of three booleans")
        for (name, open, inUse, mono, shown) in cases {
            XCTAssertEqual(PositiveRows.axesShown(open: open, mono: mono), shown, name)
            let rows = PositiveRows.visibleRows(autoColor: .uniform(true), mono: mono, axesOpen: open)
            XCTAssertEqual(rows, shown ? [.stock, .autoColor, .warmAxis, .greenAxis, .tone]
                                       : [.stock, .autoColor, .tone], name)
            // The lit title is the in-use column, whatever the fold says.
            var summary = SelectionSummary([])
            summary.colourAxesInUse = inUse
            XCTAssertEqual(DevelopRow.base.lit(summary), inUse, name)
        }
    }

    // MARK: the remembered toggle

    /// Closed until someone opens it, including for every preferences blob written before
    /// the key existed, and a choice survives a relaunch through the real store.
    @MainActor
    func testTheToggleStartsClosedAndIsRemembered() throws {
        XCTAssertFalse(Preferences().showsColourAxes, "closed by default")
        XCTAssertFalse(Preferences.load().showsColourAxes, "nothing stored reads closed")

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        json.removeValue(forKey: "colourAxesOpen")
        let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.showsColourAxes, "an older blob reads closed")

        let (m, _) = try scratchRollModel(frames: 1, in: scratch)
        m.toggleColourAxes()
        XCTAssertTrue(m.prefs.showsColourAxes)
        XCTAssertTrue(Preferences.load().showsColourAxes, "the open state is saved app-wide")
        m.toggleColourAxes()
        XCTAssertFalse(Preferences.load().showsColourAxes, "and so is closing it")
    }

    /// The fold is a preference: no sidecar byte changes and no undo step appears.
    @MainActor
    func testAdjustWritesNothing() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        seed(m, ids[0], axes: ColourAxes(warm: 4))
        m.selection = Set(ids)
        let roll = scratch.appendingPathComponent("roll")
        let before = try snapshot(roll)
        let sidecars = ids.map { m.frame($0)?.sidecar }
        let undoable = m.undoManager.undoActionName

        m.toggleColourAxes()
        m.toggleColourAxes()
        m.toggleColourAxes()

        XCTAssertEqual(try snapshot(roll), before, "no file in the roll changed")
        XCTAssertEqual(ids.map { m.frame($0)?.sidecar }, sidecars, "no sidecar in memory changed")
        XCTAssertEqual(m.undoManager.undoActionName, undoable, "no undo step was registered")
    }

    // MARK: in use, over the selection

    /// Any selected frame with a non-zero axis counts, so a mixed selection shows them.
    @MainActor
    func testInUseReadsAnyFrameOfTheSelection() throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        seed(m, ids[0], axes: ColourAxes(green: -2.5))
        seed(m, ids[1])

        m.selection = [ids[1]]
        XCTAssertFalse(m.selectionSummary.colourAxesInUse, "zero axes")
        m.selection = [ids[2]]
        XCTAssertFalse(m.selectionSummary.colourAxesInUse, "an undeveloped frame")
        m.selection = [ids[0]]
        XCTAssertTrue(m.selectionSummary.colourAxesInUse, "a non-zero green")
        m.selection = Set(ids)
        XCTAssertTrue(m.selectionSummary.colourAxesInUse, "a mixed selection with one in use shows them")

        // An offset set by hand reveals the rows on its own, and zeroing it folds them.
        m.selection = [ids[1]]
        m.applyToSelection({ ColourAxis.warm.edit($0, to: 3) }, actionName: InspectorView.colourAxesAction)
        XCTAssertTrue(m.selectionSummary.colourAxesInUse)
        m.applyToSelection({ ColourAxis.warm.edit($0, to: 0) }, actionName: InspectorView.colourAxesAction)
        XCTAssertFalse(m.selectionSummary.colourAxesInUse)
    }

    /// A black and white frame keeps its axes (so color comes back with them), and the
    /// title still reads lit while one is set, but the rows stay folded there, open or
    /// closed, set or zero, because the axes cannot move a black and white frame.
    @MainActor
    func testAMonoFrameNeverShowsTheRowsAndStillReadsLit() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        seed(m, ids[0], stock: "bw-generic", axes: ColourAxes(warm: 2))
        seed(m, ids[1], stock: "bw-generic")
        XCTAssertTrue(try XCTUnwrap(m.frame(ids[0]).map(m.isMonoStock)))

        m.selection = [ids[0]]
        XCTAssertTrue(m.selectionSummary.colourAxesInUse)
        XCTAssertTrue(DevelopRow.base.lit(m.selectionSummary), "the kept axis still lights the title")
        XCTAssertEqual(m.frame(ids[0])?.sidecar.develop?.colourAxes, ColourAxes(warm: 2), "and is kept")
        XCTAssertFalse(PositiveRows.axesShown(open: false, mono: true))
        XCTAssertFalse(PositiveRows.axesShown(open: true, mono: true))

        m.selection = [ids[1]]
        XCTAssertFalse(m.selectionSummary.colourAxesInUse)
        XCTAssertFalse(DevelopRow.base.lit(m.selectionSummary))
        XCTAssertFalse(PositiveRows.axesShown(open: true, mono: true))
    }

    /// A closed Base row with an offset hides its sliders and reads lit. Opening it shows
    /// the same offset, closing it hides them again, and neither writes a sidecar nor an
    /// undo step.
    @MainActor
    func testAClosedRowWithAnOffsetHidesItsSliders() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        seed(m, ids[0], axes: ColourAxes(warm: 4))
        m.selection = [ids[0]]
        let roll = scratch.appendingPathComponent("roll")
        let before = try snapshot(roll)
        let sidecar = m.frame(ids[0])?.sidecar
        let undoable = m.undoManager.undoActionName
        let canUndo = m.undoManager.canUndo

        XCTAssertFalse(m.prefs.showsColourAxes, "closed")
        XCTAssertTrue(DevelopRow.base.lit(m.selectionSummary), "lit")
        XCTAssertFalse(PositiveRows.axesShown(open: m.prefs.showsColourAxes, mono: false), "no sliders")

        m.toggleDevelopRow(.base)
        XCTAssertTrue(PositiveRows.axesShown(open: m.prefs.showsColourAxes, mono: false), "open shows them")
        XCTAssertEqual(m.selectionSummary.trackPosition(.warm), 4, "with the edit as it was")
        XCTAssertTrue(DevelopRow.base.lit(m.selectionSummary))

        m.toggleDevelopRow(.base)
        XCTAssertFalse(PositiveRows.axesShown(open: m.prefs.showsColourAxes, mono: false), "closed again")
        XCTAssertTrue(DevelopRow.base.lit(m.selectionSummary), "still lit")

        XCTAssertEqual(try snapshot(roll), before, "no file in the roll changed")
        XCTAssertEqual(m.frame(ids[0])?.sidecar, sidecar, "no sidecar in memory changed")
        XCTAssertEqual(m.undoManager.undoActionName, undoable, "no undo step was registered")
        XCTAssertEqual(m.undoManager.canUndo, canUndo, "no undo step was registered")
    }

    /// Reset Positive still zeroes the axes, and with the toggle closed the rows fold.
    @MainActor
    func testResetPositiveFoldsTheRowsWhenTheToggleIsClosed() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        seed(m, ids[0], axes: ColourAxes(warm: 5, green: 1))
        m.selection = [ids[0]]
        XCTAssertTrue(m.selectionSummary.colourAxesInUse)

        m.resetDevelopSelection()
        XCTAssertFalse(m.selectionSummary.colourAxesInUse, "the axes are back at zero")
        XCTAssertFalse(PositiveRows.axesShown(open: m.prefs.showsColourAxes, mono: false),
                       "and the closed toggle folds them")
    }

    /// The Base title is the fold, before Pick Base and the axis rows, lit by the axes in use
    /// and disabled on black and white.
    func testTheBaseTitleFoldsTheRows() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let pick = try XCTUnwrap(s.range(of: "PickBaseButton()"))
        let title = try XCTUnwrap(s.range(of: "DevelopRowTitle(row: .base, open: DevelopRow.base.isOpen(model.prefs),"))
        // The Base pair's rows, after Pick Base: the Stock row's own pair is earlier.
        let rows = try XCTUnwrap(s.range(of: "ForEach(ColourAxis.allCases)", range: pick.upperBound..<s.endIndex))
        XCTAssertLessThan(title.lowerBound, pick.lowerBound)
        XCTAssertLessThan(pick.lowerBound, rows.lowerBound)
        let call = String(s[title.lowerBound...].prefix(260))
        XCTAssertTrue(call.contains("lit: DevelopRow.base.lit(summary)) { model.toggleDevelopRow(.base) }"), call)
        XCTAssertTrue(call.contains(".disabled(monoSelection)"), call)
        XCTAssertEqual(DevelopRow.base.identifier, "positive.adjust", "the Adjust word's id stays on the title")
    }

    // MARK: helpers

    @MainActor
    private func seed(_ m: AppModel, _ id: Frame.ID, stock: String = "kodak-gold-200",
                      axes: ColourAxes = .identity) {
        m.undoManager.beginUndoGrouping()
        m.apply({ s in
            var develop = DevelopSettings(stock: stock, tone: .none, autoBalance: true,
                                          base: BaseSettings(mode: .anchor))
            develop.colourAxes = axes
            return SidecarEdits.setDevelop(s, develop)
        }, to: id, actionName: "seed")
        m.undoManager.endUndoGrouping()
    }

    /// Every file under the roll, by name, with its bytes.
    private func snapshot(_ roll: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: roll, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            if let d = try? Data(contentsOf: url) { out[url.path] = d }
        }
        return out
    }
}

import XCTest
@testable import FilmPositive

/// The inspector's Export is the toolbar's Export, one view in two places, pinned under the
/// scrolling form.
final class InspectorExportTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The count the way the Develop button says it: none for one frame, the count for many.
    func testTheLabelCountsTheSelection() {
        XCTAssertEqual(ExportButton.title(count: 1), "Export")
        XCTAssertEqual(ExportButton.title(count: 3), "Export (3)")
        XCTAssertEqual(ExportButton.title(count: 40), "Export (40)")
        XCTAssertEqual(ExportButton.title(count: 0), "Export", "never a zero count")
        XCTAssertEqual(PositiveButton.title(unprocessed: 3), "Develop (3)", "the shape it copies")
    }

    /// The rule is the toolbar's: anything selected can export, nothing selected cannot.
    func testTheEnabledRuleIsTheToolbars() {
        XCTAssertFalse(ExportButton.enabled(selectionCount: 0))
        XCTAssertTrue(ExportButton.enabled(selectionCount: 1))
        XCTAssertTrue(ExportButton.enabled(selectionCount: 3))
        XCTAssertEqual(ExportButton.help, "Export the selected developed frames")
    }

    /// Both places build the ONE view, so the action, the rule and the help cannot drift.
    func testBothPlacesBuildTheOneButton() throws {
        let grid = try repoSource("Sources/FilmPositive/UI/Grid/GridView.swift")
        let inspector = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let button = try repoSource("Sources/FilmPositive/UI/Export/ExportButton.swift")
        XCTAssertTrue(grid.contains("ToolbarItemGroup(placement: .primaryAction)"), "canary: read the toolbar")
        XCTAssertTrue(grid.contains("ExportButton(place: .toolbar)"))
        XCTAssertFalse(grid.contains("model.showsExportSheet = true"), "no second copy of the action in the grid")
        XCTAssertTrue(inspector.contains("ExportButton(place: .inspector)"))
        XCTAssertTrue(button.contains("Button { model.presentExport() } label: {"))
        XCTAssertTrue(button.contains(".disabled(!Self.enabled(selectionCount: model.selectedFrames.count))"))
        XCTAssertTrue(button.contains(".help(Self.help)"))
    }

    /// Outside the scrolling form, bordered, the Develop button's size, never the accent.
    func testTheInspectorButtonSitsUnderTheForm() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let form = try XCTUnwrap(s.range(of: ".formStyle(.grouped)"))
        let inset = try XCTUnwrap(s.range(of: ".safeAreaInset(edge: .bottom, spacing: 0) { exportBar }"))
        XCTAssertLessThan(form.lowerBound, inset.lowerBound, "a modifier on the Form, not a row inside it")
        let bar = try XCTUnwrap(s.range(of: "private var exportBar: some View {"))
        let body = String(s[bar.upperBound...].prefix(700))
        for piece in ["ExportButton(place: .inspector)", ".buttonStyle(.bordered)", ".controlSize(.regular)",
                      ".accessibilityIdentifier(\"inspector.export\")"] {
            XCTAssertTrue(body.contains(piece), "missing \(piece)")
        }
        XCTAssertFalse(body.contains("borderedProminent"))
        XCTAssertFalse(body.contains(".tint("))
    }

    /// A press opens the Export sheet, as the toolbar's and File > Export do.
    @MainActor
    func testAPressOpensTheSheet() throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        m.selection = Set(ids)
        XCTAssertFalse(m.showsExportSheet)
        m.presentExport()
        XCTAssertTrue(m.showsExportSheet)
        XCTAssertEqual(ExportButton.title(count: m.selectedFrames.count), "Export (3)")
    }
}

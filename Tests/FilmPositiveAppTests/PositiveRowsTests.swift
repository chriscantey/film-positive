import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Positive section: the Base control's name, the row set, the info icon beside
/// it, and the Color / Black & White write.
///
/// Every rule here is a pure function precisely so it can be asserted without a window.
/// The two the view could otherwise get wrong invisibly are the row ORDER (a SwiftUI
/// `if` reorders nothing, but a refactor can) and the derivation of the color stock
/// (nothing guessed from a neighbor reaches disk).
final class PositiveRowsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-positive-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func library() throws -> ProfileLibrary { try ProfileLibrary.bundled() }

    // MARK: the display constant

    /// The rename is a DISPLAY rename and nothing else. Both halves are asserted, because
    /// getting the first without the second is a silent data migration.
    func testTheToggleIsNamedForWhatItDoesAndTheStoredKeyIsStillAutoBalance() throws {
        XCTAssertEqual(PositiveNames.autoColor, "Auto Color")

        // The sidecar key does not move. A round trip through the real codec is what proves
        // it rather than a grep: the field is `autoBalance` in the type and `AutoBalance` in
        // the file, and the renamed label must reach neither.
        var sidecar = Sidecar(source: SidecarSource(name: "IMG_0001.CR2", size: 64,
                                                    mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                                    fingerprint: "sha256:deadbeef"))
        sidecar.develop = DevelopSettings(stock: "kodak-gold-200",
                                          tone: .none, autoBalance: false, base: BaseSettings(mode: .anchor))
        let data = try sidecar.encoded()
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(xml.contains("AutoBalance"), "the stored key stays AutoBalance")
        XCTAssertFalse(xml.contains("AutoColor"), "the display rename must not reach the file")
        XCTAssertFalse(xml.contains("FindFilmEdge"), "nor the one it had for an evening")
        let back = try Sidecar.decode(data, liveSource: sidecar.source, strict: true)
        XCTAssertEqual(back.develop?.autoBalance, false)
    }

    /// "Everywhere the user sees it" is a claim a grep can check, and the same scan
    /// `ToneNamesTests` uses for "Bold" checks it here. Comments are stripped, so the
    /// history above can keep saying what the switch used to be called.
    ///
    /// It catches the two places the old name actually lived: the toggle's `Label` and the
    /// undo action name, which is user-visible in the Edit menu.
    func testTheOldNameAppearsInNoSourceFileAsAString() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let target = root.appendingPathComponent("Sources/FilmPositive")
        var scanned = 0
        let walker = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let code = ToneNamesTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
            for (n, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for old in ["\"Auto Balance\"", "\"Find film edge\"", "\"Pick Base"] {
                    XCTAssertFalse(line.contains(old),
                                   "\(url.lastPathComponent):\(n + 1) still shows the old name \(old)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the source scan found almost nothing: wrong path?")
    }

    /// The Base control's help is one plain sentence naming all three choices.
    func testTheBaseHelpNamesAllThreeChoices() {
        XCTAssertEqual(PositiveNames.baseHelp, "Auto finds the film color, Picked uses yours, None uses none.")
        XCTAssertFalse(PositiveNames.baseHelp.contains("preset"),
                       "there is no preset base any more (2026-09-23)")
    }

    // MARK: the row set, as a table

    /// Stock leads the section and is drawn in every state. Black & White is a Stock
    /// entry. Every state of the toggle draws the same rows.
    func testTheRowSetAndItsOrderForEveryAutoColorState() {
        let cases: [(String, SharedValue<Bool?>, [PositiveRows.Row])] = [
            ("on",       .uniform(true),  [.stock, .autoColor, .warmAxis, .greenAxis, .tone]),
            ("off",      .uniform(false), [.stock, .autoColor, .warmAxis, .greenAxis, .tone]),
            ("multiple", .multiple,       [.stock, .autoColor, .warmAxis, .greenAxis, .tone]),
            // Nothing recorded renders through the defaults, and the default is on.
            ("nil",      .uniform(nil),   [.stock, .autoColor, .warmAxis, .greenAxis, .tone]),
            ("empty",    .empty,          [.stock, .autoColor, .warmAxis, .greenAxis, .tone]),
        ]
        for (name, state, expected) in cases {
            XCTAssertEqual(PositiveRows.visibleRows(autoColor: state), expected,
                           "row set and order for \(name)")
        }
    }

    /// The two row sets are subsequences of one sequence, which is what lets the view draw
    /// them in one ordered pass with `contains` and never disagree with this function about
    /// order. If a future row breaks that, this fails and the view has to change too.
    func testBothRowSetsAreSubsequencesOfTheDeclaredOrder() {
        let declared: [PositiveRows.Row] = [.stock, .autoColor, .warmAxis, .greenAxis, .tone]
        for state: SharedValue<Bool?> in [.uniform(true), .uniform(false), .multiple] {
            let rows = PositiveRows.visibleRows(autoColor: state)
            XCTAssertEqual(rows, declared.filter { rows.contains($0) },
                           "the view's ordered pass must reproduce \(rows)")
        }
    }

    /// The Stock rule, as the thing a user sees: NO state of the app can hide Stock, and it
    /// is always first.
    func testNoAutoColorStateHidesStockAndStockLeadsTheSection() {
        let states: [SharedValue<Bool?>] = [.uniform(true), .uniform(false), .uniform(nil),
                                            .multiple, .empty]
        for state in states {
            let rows = PositiveRows.visibleRows(autoColor: state)
            XCTAssertTrue(rows.contains(.stock), "Stock is hidden for \(state)")
            XCTAssertEqual(rows.first, .stock, "Stock leads the section")
        }
    }

    /// A black and white selection never draws the color axis rows, whatever the toggle
    /// says. A mono frame has no mask to correct, so they would be controls with no
    /// effect.
    func testAMonoSelectionDrawsNoColourRows() {
        for state: SharedValue<Bool?> in [.uniform(true), .uniform(false), .uniform(nil), .multiple] {
            let rows = PositiveRows.visibleRows(autoColor: state, mono: true)
            XCTAssertEqual(rows, [.stock, .autoColor, .tone], "mono rows for \(state)")
        }
        // And the color answer is unchanged, so `mono` is the whole of the difference.
        XCTAssertEqual(PositiveRows.visibleRows(autoColor: .uniform(false), mono: false),
                       [.stock, .autoColor, .warmAxis, .greenAxis, .tone])
        // The help the disabled toggle carries, which is the other half of the same rule.
        XCTAssertEqual(PositiveNames.monoHelp, "Black and white film has no film color.")
    }

    /// The toggle does not change the row set at all.
    func testAutoColorNoLongerChangesTheRowSet() {
        XCTAssertEqual(PositiveRows.visibleRows(autoColor: .uniform(true)),
                       PositiveRows.visibleRows(autoColor: .uniform(false)))
    }

    // MARK: the info icon beside Auto color

    /// The words, per state, from one place. The icon's tooltip and popover both read
    /// `BaseSource.status`, so this pins both.
    func testTheInfoIconSaysEachStateFromOnePlace() {
        XCTAssertEqual(BaseSource.edge(BaseRatios(rg: 0.47, bg: 0.72)).status, "Color from the film border")
        XCTAssertEqual(BaseSource.estimated(BaseRatios(rg: 0.5, bg: 0.7)).status, "Color estimated from the picture")
        XCTAssertEqual(BaseSource.picked.status, "Color from your pick")
        XCTAssertEqual(BaseSource.notFound.status, "Could not find the film border. Pick a spot on the film.")
        XCTAssertEqual(BaseSource.blackAndWhite.status, "Black and white film")
        XCTAssertEqual(BaseSource.off.status, "No film color in use.")
    }

    /// The glyph alone carries the one state worth acting on: a warning mark when the
    /// border could not be found, the plain i for everything else, including off.
    func testTheGlyphIsAWarningOnlyWhenTheBorderWasNotFound() {
        XCTAssertEqual(BaseInfo.symbol(for: .notFound), "exclamationmark.triangle")
        for s: BaseSource? in [.picked, .edge(BaseRatios(rg: 0.5, bg: 0.8)),
                                .estimated(BaseRatios(rg: 0.5, bg: 0.8)), .off, .blackAndWhite, nil] {
            XCTAssertEqual(BaseInfo.symbol(for: s), "info.circle", "\(String(describing: s))")
        }
    }

    /// The sidecar decides black and white, picked and off at once, whatever an older render
    /// said. Only a switch-on frame waits on its render, and only a switch-on answer from
    /// that render is believed.
    func testOneFrameSourceTakesTheSidecarRungsAtOnceAndTheRenderOnlyForSwitchOn() throws {
        let lib = try library()
        let edge = BaseSource.edge(BaseRatios(rg: 0.47, bg: 0.72))
        func develop(_ stock: String = "kodak-gold-200", auto: Bool = true,
                     picked: BaseRatios? = nil) -> DevelopSettings {
            DevelopSettings(stock: stock, tone: .flat, autoBalance: auto,
                            base: picked.map { BaseSettings(mode: .measured, ratios: $0) } ?? BaseSettings(mode: .anchor))
        }

        XCTAssertEqual(BaseInfo.source(develop: develop(), profiles: lib, rendered: edge), edge)
        XCTAssertEqual(BaseInfo.source(develop: develop(), profiles: lib, rendered: .notFound), .notFound)
        XCTAssertNil(BaseInfo.source(develop: develop(), profiles: lib, rendered: nil), "not rendered yet")
        XCTAssertNil(BaseInfo.source(develop: develop(), profiles: lib, rendered: .off),
                     "a render from before the switch went on is stale")

        XCTAssertEqual(BaseInfo.source(develop: develop(auto: false), profiles: lib, rendered: edge), .off,
                       "the switch just went off and the render has not caught up")
        XCTAssertEqual(BaseInfo.source(develop: develop(picked: BaseRatios(rg: 0.5, bg: 0.7)),
                                       profiles: lib, rendered: .notFound), .picked)
        XCTAssertEqual(BaseInfo.source(develop: develop("bw-generic"), profiles: lib, rendered: nil),
                       .blackAndWhite)
        XCTAssertNil(BaseInfo.source(develop: nil, profiles: lib, rendered: edge), "no develop layer")
    }

    /// A border not found anywhere in the selection wins, because it is the one state a
    /// person can act on. Otherwise the lead frame, which comes first.
    func testASelectionShowsNotFoundFromAnyFrameAndOtherwiseTheLead() {
        let edge = BaseSource.edge(BaseRatios(rg: 0.47, bg: 0.72))
        XCTAssertEqual(BaseInfo.selection([edge, .picked, .notFound]), .notFound)
        XCTAssertEqual(BaseInfo.selection([.picked, edge]), .picked)
        XCTAssertEqual(BaseInfo.selection([nil, edge]), nil)
        XCTAssertEqual(BaseInfo.selection([]), nil)
    }

    /// When the warning belongs to another selected frame, the words say how many of
    /// the selection it covers, because the lead frame on screen developed from its border
    /// and the plain status would contradict it. The lead's own warning, or a selection of
    /// one, keeps the plain status.
    func testAWarningFromAnotherSelectedFrameNamesTheCount() {
        let edge = BaseSource.edge(BaseRatios(rg: 0.47, bg: 0.72))
        let counted = BaseInfo.status([edge, .notFound, edge])
        XCTAssertEqual(counted, "No film border found on 1 of 3 frames. Pick a spot on the film.")
        XCTAssertNotEqual(counted, BaseSource.notFound.status, "the lead frame's border was found")
        XCTAssertEqual(BaseInfo.status([edge, .notFound, .notFound, nil]),
                       "No film border found on 2 of 4 frames. Pick a spot on the film.")
        XCTAssertEqual(BaseInfo.status([.notFound, edge]), BaseSource.notFound.status, "the lead warns itself")
        XCTAssertEqual(BaseInfo.status([.notFound]), BaseSource.notFound.status)
        XCTAssertEqual(BaseInfo.status([edge]), edge.status)
        XCTAssertEqual(BaseInfo.status([edge, .picked]), edge.status)
        XCTAssertEqual(BaseInfo.status([nil]), "")
        XCTAssertEqual(BaseInfo.status([]), "")
    }

    /// The accessor must be a pure read. A service that has never been asked to render
    /// answers `.notComputed`, and asking cannot make it compute.
    func testTheAccessorReadsTheMemoAndComputesNothing() throws {
        let service = CountingRebateService()
        let url = scratch.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 64).write(to: url)

        XCTAssertEqual(service.rebateStatus(for: url), .notComputed)
        XCTAssertEqual(service.asked, 1)
        XCTAssertEqual(service.computed, 0, "reading the memo must not measure anything")

        service.answer = .refused
        XCTAssertEqual(service.rebateStatus(for: url), .refused)
        service.answer = .found([10, 20, 30])
        XCTAssertEqual(service.rebateStatus(for: url), .found([10, 20, 30]))
        XCTAssertEqual(service.computed, 0)
    }

    /// The protocol default, which every stand-in service in the suite inherits. A service
    /// with no memo has nothing to report, and nothing to report is not a refusal.
    func testAServiceWithNoMemoAnswersNotComputedRatherThanRefused() {
        let bare = FailingRenderService(message: "no engine in this test")
        XCTAssertEqual(bare.rebateStatus(for: URL(fileURLWithPath: "/tmp/nope.CR2")), .notComputed)
    }

    // MARK: the write, through the model

    /// The Stock picker is now the ONLY way to say "this is black and white", so the two
    /// ids it writes are asserted through `applyToSelection`, which is the funnel the
    /// binding uses.
    @MainActor
    func testTheBlackAndWhiteEntryWritesTheMonoIDAndColorNegativeWritesGeneric() throws {
        let (model, ids) = try modelWithFolder(count: 2)
        model.selection = Set(ids)

        applyStock(model, ProfileLibrary.monoStockID)
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.develop?.stock, ProfileLibrary.monoStockID)
        }
        XCTAssertEqual(ProfileLibrary.monoStockID, "bw-generic",
                       "the id the Black & White Negative entry writes")

        applyStock(model, ProfileLibrary.genericStockName)
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.develop?.stock, ProfileLibrary.genericStockName)
        }
        XCTAssertEqual(ProfileLibrary.genericStockName, "generic",
                       "the id the Color Negative entry writes, unchanged by the rename")
    }

    // MARK: helpers

    @MainActor
    private func modelWithFolder(count: Int) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    /// Exactly what `InspectorView.stockBinding`'s setter does. Duplicated here rather
    /// than reached through the view, because a `Binding` needs a live SwiftUI graph and
    /// the rule under test is the write, not the plumbing.
    @MainActor
    private func applyStock(_ model: AppModel, _ newID: String) {
        model.applyToSelection({ sidecar in
            guard var develop = sidecar.develop else { return sidecar }
            develop.stock = newID
            return SidecarEdits.setDevelop(sidecar, develop)
        }, actionName: "Stock")
    }
}

/// A service whose `rebateStatus` answer is scripted, and which counts both how often it is
/// asked and how often it would have measured. The second count is the one that matters:
/// the inspector must not be able to start a render, so the accessor being a pure read is
/// the property under test.
private final class CountingRebateService: RenderService, @unchecked Sendable {
    var answer: RebateStatus = .notComputed
    private(set) var asked = 0
    private(set) var computed = 0

    func render(_ request: RenderRequest) async throws -> RenderResult {
        computed += 1
        throw RenderError.badRotation(0)
    }

    func rebateStatus(for url: URL) -> RebateStatus {
        asked += 1
        return answer
    }
}

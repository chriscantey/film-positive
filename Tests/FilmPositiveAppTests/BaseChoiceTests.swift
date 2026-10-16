import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The three-way Base control, Auto, Picked and None. It is a VIEW of `base.mode`,
/// `base.ratios` and `autoBalance`, so these lock the mapping both ways, the sidecars already
/// on disk, the model's write and the black and white rule. The resolver's half (the mode
/// decides whether a stored pair is used) is
/// `RebateBaseTests.testTheBaseModeDecidesWhetherAStoredPairIsUsed`.
final class BaseChoiceTests: XCTestCase {

    private let pair = BaseRatios(rg: 0.47, bg: 0.70)

    private func develop(mode: BaseSettings.Mode, ratios: BaseRatios?, on: Bool) -> DevelopSettings {
        DevelopSettings(stock: "kodak-gold-200", tone: .none, autoBalance: on,
                        base: BaseSettings(mode: mode, ratios: ratios))
    }

    // MARK: the mapping

    /// Every combination the two fields can hold reads as exactly one segment.
    func testEveryStoredStateReadsAsOneSegment() {
        let cases: [(String, DevelopSettings, BaseChoice)] = [
            ("measured with a pair, switch on", develop(mode: .measured, ratios: pair, on: true), .picked),
            ("measured with a pair, switch off", develop(mode: .measured, ratios: pair, on: false), .picked),
            ("measured with no pair is not a pick", develop(mode: .measured, ratios: nil, on: true), .auto),
            ("anchor, switch on", develop(mode: .anchor, ratios: nil, on: true), .auto),
            ("anchor, switch off", develop(mode: .anchor, ratios: nil, on: false), .none),
            ("anchor keeping a pair, switch on", develop(mode: .anchor, ratios: pair, on: true), .auto),
            ("anchor keeping a pair, switch off", develop(mode: .anchor, ratios: pair, on: false), .none),
        ]
        for (name, d, want) in cases {
            XCTAssertEqual(BaseChoice(d), want, name)
        }
    }

    /// Each choice written reads back as itself, Auto and None keep the pair, and Picked
    /// comes back from either without a second pick.
    func testWritingAChoiceReadsBackAndKeepsThePair() throws {
        let picked = develop(mode: .measured, ratios: pair, on: true)

        let auto = try XCTUnwrap(BaseChoice.auto.applied(to: picked))
        XCTAssertEqual(BaseChoice(auto), .auto)
        XCTAssertEqual(auto.base.mode, .anchor)
        XCTAssertTrue(auto.autoBalance)
        XCTAssertEqual(auto.base.ratios, pair, "Auto after a pick keeps the pair")

        let none = try XCTUnwrap(BaseChoice.none.applied(to: auto))
        XCTAssertEqual(BaseChoice(none), .none)
        XCTAssertFalse(none.autoBalance)
        XCTAssertEqual(none.base.ratios, pair, "None keeps it too")

        let back = try XCTUnwrap(BaseChoice.picked.applied(to: none))
        XCTAssertEqual(BaseChoice(back), .picked, "Picked again without picking")
        XCTAssertEqual(back.base.ratios, pair)
        XCTAssertEqual(back.base.mode, .measured)

        XCTAssertNil(BaseChoice.picked.applied(to: develop(mode: .anchor, ratios: nil, on: true)),
                     "Picked with no stored pair cannot be written from the sidecar alone")
        XCTAssertEqual(BaseChoice.allCases.map(\.title), ["Auto", "Picked", "None"])
    }

    // MARK: sidecars already on disk

    /// Through the real codec, so the file format is what is under test. No key was added:
    /// the three states come from `BaseMode`, `BaseRG`/`BaseBG` and `AutoBalance`, and an
    /// old file with no `AutoBalance` at all reads as Auto, as it rendered before.
    func testOldSidecarsReadStraightIntoTheControl() throws {
        func roundTrip(_ d: DevelopSettings, strip: String? = nil) throws -> (DevelopSettings, String) {
            // `strip` is a regular expression cut out of the encoded file before decoding.
            var sidecar = Sidecar(source: SidecarSource(name: "IMG_0001.CR2", size: 64,
                                                        mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                                        fingerprint: "sha256:deadbeef"))
            sidecar.develop = d
            var xml = try XCTUnwrap(String(data: try sidecar.encoded(), encoding: .utf8))
            if let strip { xml = xml.replacingOccurrences(of: strip, with: "", options: .regularExpression) }
            let back = try Sidecar.decode(Data(xml.utf8), liveSource: sidecar.source)
            return (try XCTUnwrap(back.develop), xml)
        }

        let (picked, xml) = try roundTrip(develop(mode: .measured, ratios: pair, on: true))
        XCTAssertTrue(xml.contains("BaseMode=\"measured\""), "the file says measured")
        XCTAssertEqual(BaseChoice(picked), .picked)

        XCTAssertEqual(BaseChoice(try roundTrip(develop(mode: .anchor, ratios: nil, on: true)).0), .auto)
        XCTAssertEqual(BaseChoice(try roundTrip(develop(mode: .anchor, ratios: nil, on: false)).0), .none)

        let (legacy, legacyXML) = try roundTrip(develop(mode: .anchor, ratios: nil, on: false),
                                                strip: #"\s[A-Za-z]+:AutoBalance="[^"]*""#)
        XCTAssertFalse(legacyXML.contains("AutoBalance"), "the key really is gone from the file")
        XCTAssertEqual(BaseChoice(legacy), .auto, "a file from before the switch reads Auto")

        // A pick kept under Auto survives the file, so Picked can come back after a reopen.
        let (kept, _) = try roundTrip(develop(mode: .anchor, ratios: pair, on: true))
        XCTAssertEqual(BaseChoice(kept), .auto)
        XCTAssertEqual(kept.base.ratios, pair)
    }

    // MARK: the model's write

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-base-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    private func model(count: Int) throws -> (AppModel, [Frame.ID]) {
        let roll = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64)
                .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let m = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        m.undoManager.groupsByEvent = false
        XCTAssertNotNil(m.addFolder(roll))
        let ids = (m.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (m, ids)
    }

    @MainActor
    private func seed(_ m: AppModel, _ id: Frame.ID, _ edit: (inout DevelopSettings) -> Void) {
        guard let frame = m.frame(id),
              var develop = frame.sidecar.develop ?? m.renders.defaults.initial(for: frame.sidecar) else {
            return XCTFail("no defaults for the frame")
        }
        edit(&develop)
        m.undoManager.beginUndoGrouping()
        m.apply({ SidecarEdits.setDevelop($0, develop) }, to: id, actionName: "seed")
        m.undoManager.endUndoGrouping()
    }

    @MainActor
    private func choice(_ m: AppModel, _ id: Frame.ID) -> BaseChoice? {
        m.frame(id)?.sidecar.develop.map(BaseChoice.init)
    }

    /// One click, one undo step, over every selected frame.
    @MainActor
    func testAChoiceWritesTheSelectionAsOneUndoStep() throws {
        let (m, ids) = try model(count: 3)
        m.selection = [ids[0], ids[1]]
        XCTAssertEqual(m.selectionSummary.baseChoice, .uniform(.auto), "a fresh roll reads Auto")

        XCTAssertTrue(m.chooseBase(.none))
        XCTAssertEqual(choice(m, ids[0]), BaseChoice.none)
        XCTAssertEqual(choice(m, ids[1]), BaseChoice.none)
        XCTAssertNil(m.frame(ids[2])?.sidecar.develop, "the unselected frame is untouched")
        XCTAssertEqual(m.selectionSummary.baseChoice, .uniform(.none))

        m.undoManager.undo()
        XCTAssertEqual(m.selectionSummary.baseChoice, .uniform(.auto), "one undo restores both")
    }

    /// Picked with no stored pair writes nothing and starts Pick Base, the pick that completes
    /// reads Picked, and Auto then Picked needs no second pick.
    @MainActor
    func testPickedStartsPickBaseAndAKeptPairComesBack() throws {
        let (m, ids) = try model(count: 2)
        m.selection = [ids[0]]

        XCTAssertFalse(m.chooseBase(.picked), "reports that it wrote nothing, so the control redraws")
        XCTAssertTrue(m.isPickingBase, "no pair stored, so Picked starts Pick Base")
        XCTAssertNil(m.frame(ids[0])?.sidecar.develop, "and writes nothing")

        m.applyPickedBase([14100, 30000, 21000], to: m.pickBaseTargets)
        XCTAssertFalse(m.isPickingBase)
        XCTAssertEqual(m.selectionSummary.baseChoice, .uniform(.picked), "a completed pick selects Picked")
        let stored = try XCTUnwrap(m.frame(ids[0])?.sidecar.develop?.base.ratios)

        m.chooseBase(.auto)
        XCTAssertEqual(choice(m, ids[0]), .auto)
        XCTAssertEqual(m.frame(ids[0])?.sidecar.develop?.base.ratios, stored, "Auto keeps the pick")

        m.chooseBase(.picked)
        XCTAssertFalse(m.isPickingBase, "the pair is there, so no second pick")
        XCTAssertEqual(choice(m, ids[0]), .picked)
        XCTAssertEqual(m.frame(ids[0])?.sidecar.develop?.base.ratios, stored)
    }

    /// A selection that disagrees shows no segment, and one click agrees it.
    @MainActor
    func testAMixedSelectionShowsNoSegment() throws {
        let (m, ids) = try model(count: 2)
        seed(m, ids[0]) { $0.autoBalance = false }
        seed(m, ids[1]) { $0.autoBalance = true }
        m.selection = [ids[0], ids[1]]
        XCTAssertTrue(m.selectionSummary.baseChoice.isMultiple)
        XCTAssertNil(m.selectionSummary.baseChoice.value, "no segment is lit")

        m.chooseBase(.auto)
        XCTAssertEqual(m.selectionSummary.baseChoice, .uniform(.auto))
    }

    /// Black and white: nothing is written to a mono frame, so its stored choice is still
    /// there when the stock goes back to color. The picker draws None and disabled from
    /// `monoSelection`, the same agreement rule as the eyedropper.
    @MainActor
    func testAMonoFrameKeepsItsStoredChoice() throws {
        let (m, ids) = try model(count: 2)
        seed(m, ids[0]) { $0.stock = "bw-generic"; $0.autoBalance = false }
        XCTAssertTrue(try XCTUnwrap(m.frame(ids[0]).map(m.isMonoStock)))

        m.selection = [ids[0]]
        m.chooseBase(.auto)
        XCTAssertEqual(choice(m, ids[0]), BaseChoice.none, "an all-mono selection writes nothing")

        m.selection = [ids[0], ids[1]]
        m.chooseBase(.none)
        XCTAssertEqual(choice(m, ids[1]), BaseChoice.none, "the colour frame is written")
        m.chooseBase(.auto)
        XCTAssertEqual(choice(m, ids[1]), .auto)
        XCTAssertEqual(choice(m, ids[0]), BaseChoice.none, "the mono frame keeps what it had")

        seed(m, ids[0]) { $0.stock = "kodak-gold-200" }
        XCTAssertEqual(choice(m, ids[0]), BaseChoice.none, "back to colour, the stored None returns")
    }

    // MARK: the row label

    /// The Base row reads like Stock and Tone and sits between them. On the left the icon,
    /// the word Base and the row's info icon; on the right the segmented control, small as
    /// Tone's is, with its own label hidden so the row's is the only one. The eyedropper sits
    /// between the two. The title itself (icon and word) is the button that folds the axis
    /// rows. Stock's title is a plain label.
    ///
    /// The fit at the 360 pt inspector is proven by Accessibility frames, not here, but the
    /// two choices it rests on are locked: no `LabeledContent` (a grouped Form wraps its
    /// content under the label at that width) and a small segmented control.
    func testTheBaseRowIsLabelledLikeStockAndTone() throws {
        let s = try repoSource("Sources/FilmPositive/UI/Inspector/InspectorView.swift")
        let stock = try XCTUnwrap(s.range(of: "Label(StockChoices.rowTitle, systemImage: StockChoices.rowSymbol)"))
        let base = try XCTUnwrap(s.range(of: "DevelopRowTitle(row: .base,"),
                                 "the Base row has no leading title")
        let tone = try XCTUnwrap(s.range(of: "DevelopRowTitle(row: .tone,"))
        XCTAssertEqual(DevelopRow.base.title, PositiveNames.base)
        XCTAssertEqual(DevelopRow.base.symbol, PositiveNames.baseSymbol)
        XCTAssertLessThan(stock.lowerBound, base.lowerBound)
        XCTAssertLessThan(base.lowerBound, tone.lowerBound)

        // The row opens with the label group: the Label, then the info icon.
        let row = try XCTUnwrap(s.range(of: "HStack(spacing: 8) {\n", options: .backwards,
                                        range: stock.upperBound..<base.lowerBound))
        let group = try XCTUnwrap(s.range(of: "HStack(spacing: 4) {", range: row.upperBound..<base.lowerBound))
        XCTAssertFalse(s[row.upperBound..<group.lowerBound].contains(where: { !$0.isWhitespace }),
                       "the label group is the row's first child")
        XCTAssertFalse(s[group.upperBound..<base.lowerBound].contains(where: { !$0.isWhitespace }),
                       "the title is the group's first child")
        let info = try XCTUnwrap(s.range(of: "BaseInfoButton(", range: base.upperBound..<s.endIndex))
        let pick = try XCTUnwrap(s.range(of: "PickBaseButton()"))
        let picker = try XCTUnwrap(s.range(of: "Picker(PositiveNames.base, selection: baseChoiceBinding)"))
        // The Base row's own axis rows. The Stock row carries two of its own, earlier in the
        // file.
        let axes = try XCTUnwrap(s.range(of: "ForEach(ColourAxis.allCases)", range: base.upperBound..<s.endIndex))
        XCTAssertFalse(s[base.lowerBound..<axes.lowerBound].contains("AutoTextButton("), "no Adjust word in the row")
        for (a, b, why) in [(base, info, "the title before the info icon"),
                            (info, pick, "info icon before the eyedropper"),
                            (pick, picker, "the segmented control is last, on the right"),
                            (picker, axes, "and the row ends before the axis rows")] {
            XCTAssertLessThan(a.lowerBound, b.lowerBound, why)
        }

        let rowSource = s[row.lowerBound..<axes.lowerBound]
        XCTAssertFalse(rowSource.contains("LabeledContent {"), "a grouped Form wraps LabeledContent at 360 pt")
        let pickerSource = s[picker.lowerBound..<axes.lowerBound]
        XCTAssertTrue(pickerSource.contains(".controlSize(.small)"), "the regular size does not fit beside the label")
        XCTAssertTrue(pickerSource.contains(".labelsHidden()"), "the row's Label is the only Base label")

        XCTAssertEqual(PositiveNames.base, "Base")
        XCTAssertNotNil(NSImage(systemSymbolName: PositiveNames.baseSymbol, accessibilityDescription: nil),
                        "the Base icon must be a real symbol on this OS, or the row draws the word alone")
    }
}

import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Vignette is its own Enhance group, Amount, Size and Softness, and the two new sliders
/// travel everywhere a slider travels: Reset, Copy and Paste Settings, saved Looks, a
/// multi-selection, the sidecar. No wand writes them.
final class VignetteGroupTests: XCTestCase {

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

    static func control(_ id: String) -> EnhanceControl { EnhanceControl.all.first { $0.id == id }! }
    static let amount = control("vignette")
    static let size = control("vignetteSize")
    static let softness = control("vignetteFeather")
    static let three = [amount, size, softness]

    static func blank(_ name: String) -> Sidecar {
        Sidecar(source: SidecarSource(name: name, size: 1, mtime: Date(timeIntervalSince1970: 0), fingerprint: "sha256:00"))
    }

    /// Amount, Size and Softness on, through the controls, as the rows write them.
    static var shaped: EnhanceSettings {
        var e = amount.setting(.identity, to: 0.5)
        e = size.setting(e, to: 0.3)
        return softness.setting(e, to: -0.4)
    }

    // MARK: the group

    func testTheGroupIsLastAndHoldsTheThree() {
        XCTAssertEqual(EnhanceControl.Group.allCases.last, .vignette)
        XCTAssertEqual(EnhanceControl.Group.vignette.rawValue, "Vignette")
        XCTAssertEqual(EnhanceControl.group(.vignette).map(\.label), ["Amount", "Size", "Softness"])
        XCTAssertEqual(EnhanceControl.group(.vignette).map(\.id), ["vignette", "vignetteSize", "vignetteFeather"])
        XCTAssertEqual(EnhanceControl.group(.detail).count, 6)
        XCTAssertFalse(EnhanceControl.group(.detail).contains { $0.id.hasPrefix("vignette") })
        XCTAssertTrue(EnhanceControl.coversSliderKeys)
        XCTAssertTrue(EnhanceControl.idsAreUnique)
        XCTAssertTrue(EnhanceControl.pathsAreUnique)
    }

    @MainActor
    func testTheInspectorChecksPass() throws {
        XCTAssertEqual(InspectorChecks.runAll(profiles: try ProfileLibrary.bundled()).failed, [])
    }

    /// Amount is the old Vignette row: same id, same stored meaning, same sign.
    func testAmountKeepsTheOldVignettesMeaning() {
        XCTAssertEqual(Self.amount.sign, -1)
        XCTAssertEqual(Self.amount.path, \EnhanceSettings.vignette)
        XCTAssertEqual(Self.amount.setting(.identity, to: 0.4).vignette, -0.4, "right on the slider stores negative")
        XCTAssertEqual(Self.size.sign, 1)
        XCTAssertEqual(Self.softness.sign, 1)
        XCTAssertEqual(Self.size.setting(.identity, to: 0.4).vignetteSize, 0.4)
        XCTAssertEqual(Self.softness.setting(.identity, to: -0.4).vignetteFeather, -0.4)
        // A typed value past the shown span is stored, as on every row, and the render clamps.
        XCTAssertEqual(Self.size.setting(.identity, to: 3).vignetteSize, 3)
    }

    /// The hover help, one short sentence first, then the row's click help.
    func testTheRowsSayWhatTheyDo() {
        XCTAssertEqual(Self.amount.help, "Darkens or lightens the edges.")
        XCTAssertEqual(Self.size.help, "How far the vignette reaches toward the center.")
        XCTAssertEqual(Self.softness.help, "How gradual the vignette's edge is.")
        XCTAssertEqual(EnhanceSliderRow.help(for: Self.size, isMultiple: false),
                       "How far the vignette reaches toward the center. " + SliderHelp.single)
        XCTAssertEqual(EnhanceSliderRow.help(for: Self.size, isMultiple: true),
                       "How far the vignette reaches toward the center. " + SliderHelp.mixed)
        let contrast = Self.control("contrast")
        XCTAssertNil(contrast.help)
        XCTAssertEqual(EnhanceSliderRow.help(for: contrast, isMultiple: false), SliderHelp.single, "other rows unchanged")
        for c in Self.three {
            let h = c.help ?? ""
            XCTAssertFalse(h.contains("\u{2014}") || h.contains(";") || h.contains("--"), h)
            XCTAssertLessThanOrEqual(h.count, 60, h)
        }
    }

    /// The fold: its own, appended, titled Vignette, and stored by an id that never changes.
    func testTheGroupFolds() {
        XCTAssertEqual(InspectorSection.group(.vignette), .vignette)
        XCTAssertEqual(InspectorSection.vignette.title, "Vignette")
        // Appended after Metadata, with Levels and Curves appended after it in turn.
        let all = InspectorSection.allCases.map { $0 }
        XCTAssertEqual(all.firstIndex(of: .vignette), all.firstIndex(of: .metadata).map { $0 + 1 })
        XCTAssertTrue(SectionFold().isOpen(.vignette), "open by default, like the other groups")
        let folded = SectionFold().toggled(.vignette)
        XCTAssertFalse(folded.isOpen(.vignette))
        XCTAssertTrue(folded.isOpen(.detail), "Detail stays open")
        XCTAssertEqual(folded.stored["vignette"], false)
        XCTAssertEqual(SectionFold(stored: ["detail": false]).isOpen(.vignette), true, "an older stored fold leaves it open")
    }

    // MARK: carries

    func testAOneControlEditWritesOnlyItself() {
        for c in Self.three {
            let moved = c.setting(.identity, to: 0.5)
            for key in EnhanceSettings.sliderKeys {
                let i = EnhanceSettings.sliderKeys.firstIndex(of: key)!
                XCTAssertEqual(moved.values[i], key == c.id ? 0.5 * c.sign : 0, "\(c.id) moved \(key)")
            }
        }
    }

    /// The sidecar gains the two keys, and a read gives them back.
    func testTheSidecarCarriesTheKeys() throws {
        let image = scratch.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 64).write(to: image)
        let source = try SidecarStore.source(for: image)
        let xmp = String(decoding: try Sidecar(source: source, enhance: Self.shaped).encoded(), as: UTF8.self)
        XCTAssertTrue(xmp.contains("VignetteSize"), xmp)
        XCTAssertTrue(xmp.contains("VignetteFeather"), xmp)
        try Data(xmp.utf8).write(to: SidecarStore.sidecarURL(for: image))
        let frame = try XCTUnwrap(try FolderSession.scan(scratch).first)
        XCTAssertEqual(frame.sidecar.enhance, Self.shaped, "read back through the live filter")
        XCTAssertEqual(EnhanceControl.live(Self.shaped), Self.shaped, "neither key is cut as retired")
    }

    func testCopyAndPasteSettingsCarryThem() throws {
        var from = Self.blank("a.CR2")
        from.enhance = Self.shaped
        let payload = try XCTUnwrap(FrameSettingsPayload.copying([.enhance], from: from))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        FrameSettingsPasteboard.write(payload, to: board)
        let read = try XCTUnwrap(FrameSettingsPasteboard.read(from: board))
        let target = read.applied(to: Self.blank("b.CR2"))
        XCTAssertEqual(target.enhance?.vignetteSize, 0.3)
        XCTAssertEqual(target.enhance?.vignetteFeather, -0.4)
        XCTAssertEqual(target.enhance, Self.shaped)
    }

    func testASavedLookCarriesThem() throws {
        let dir = scratch.appendingPathComponent("looks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var store = LookStore(directory: dir)
        _ = store.load()
        let saved = try store.saveLook(named: "Edges", settings: Self.shaped)
        XCTAssertEqual(saved.settings, Self.shaped)
        var reopened = LookStore(directory: dir)
        _ = reopened.load()
        XCTAssertEqual(reopened.userLooks.first?.settings, Self.shaped, "after a relaunch")
        XCTAssertEqual(LookStore.quantized(Self.shaped), Self.shaped)
        let applied = SidecarEdits.applyLook(Self.blank("c.CR2"), saved)
        XCTAssertEqual(applied.enhance, Self.shaped)
    }

    /// Neither wand writes them. The Enhance wand writes its values over a zeroed layer, so
    /// it leaves the whole Vignette group at 0, Amount included.
    /// The Color wand writes Warmth and Tint and keeps every other slider.
    func testNoWandWritesThem() {
        let proposal = AutoEnhance.Proposal(blackPoint: 0.1, brightness: 0.2, highlights: -0.1, saturation: 0.1,
                                            vibrance: 0.1, warmth: 0.05, tint: -0.02, shadows: 0.1, exposure: 0.1)
        var carrying = Self.blank("d.CR2")
        carrying.enhance = Self.shaped
        let wand = AppModel.autoEnhanceEdit(carrying, proposal).enhance ?? .identity
        XCTAssertEqual(wand.vignetteSize, 0)
        XCTAssertEqual(wand.vignetteFeather, 0)
        XCTAssertEqual(wand.vignette, 0)
        // Over a layer that holds them, the proposal's own write leaves them where they were.
        let over = proposal.applied(to: Self.shaped)
        XCTAssertEqual(over.vignetteSize, 0.3)
        XCTAssertEqual(over.vignetteFeather, -0.4)

        let colour = SidecarEdits.applyColorAuto(carrying, WarmthTint(warmth: 0.1, tint: 0.05)).enhance
        XCTAssertEqual(colour?.vignetteSize, 0.3)
        XCTAssertEqual(colour?.vignetteFeather, -0.4)
        XCTAssertEqual(SidecarEdits.clearColorAuto(carrying).enhance?.vignetteSize, 0.3)
    }

    // MARK: a selection

    @MainActor
    private func modelWithFolder(count: Int = 3) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    /// The inspector's write for one row (`InspectorView.setEnhance`), over the selection.
    @MainActor
    private func set(_ model: AppModel, _ control: EnhanceControl, _ value: Double) {
        model.applyToSelection({ sidecar in
            let current = sidecar.enhance ?? .identity
            let updated = control.setting(current, to: value)
            guard updated != current else { return sidecar }
            return SidecarEdits.setEnhance(sidecar, updated)
        }, actionName: control.label)
    }

    @MainActor
    func testASelectionEditReachesEveryFrameReadsMultipleUndoesAndResets() throws {
        let (model, ids) = try modelWithFolder()
        model.selection = Set(ids)
        model.undoManager.removeAllActions()
        set(model, Self.size, 0.6)
        set(model, Self.softness, -0.3)
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.vignetteSize, 0.6, "every selected frame")
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.vignetteFeather, -0.3)
        }
        XCTAssertEqual(model.selectionSummary.value(for: Self.size).value, 0.6)

        // One frame differs: the row reads Multiple.
        model.selection = [ids[0]]
        set(model, Self.size, -0.2)
        model.selection = Set(ids)
        XCTAssertTrue(model.selectionSummary.value(for: Self.size).isMultiple)
        XCTAssertFalse(model.selectionSummary.value(for: Self.softness).isMultiple)

        // One Undo takes back one edit, on every frame it touched.
        model.undoManager.undo()
        XCTAssertFalse(model.selectionSummary.value(for: Self.size).isMultiple)
        XCTAssertEqual(model.frame(ids[0])?.sidecar.enhance?.vignetteSize, 0.6)

        // Reset Enhance clears them with the rest of the layer.
        model.resetEnhanceSelection()
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.vignetteSize ?? 0, 0)
            XCTAssertEqual(model.frame(id)?.sidecar.enhance?.vignetteFeather ?? 0, 0)
        }
        // And a row's own reset (double-click, or its glyph) is a write of 0.
        set(model, Self.softness, 0.5)
        set(model, Self.softness, 0)
        XCTAssertNil(model.frame(ids[1])?.sidecar.enhance, "0 everywhere is no enhance layer at all")
    }
}

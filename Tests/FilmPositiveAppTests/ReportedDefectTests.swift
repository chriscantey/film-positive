import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// One test per reported defect.
///
/// Every test here is written so it would have FAILED against the reported behavior, which
/// is the only way to know a test is about the bug rather than about the code that replaced
/// it. The names say what each one guards.
final class ReportedDefectTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: the Auto Balance caption is gone
    //
    // The Auto Color row carries one `exclamationmark.triangle` in place of a caption, driven
    // from the memoized film-edge estimate rather than from a completed render. Its rules are
    // asserted in `PositiveRowsTests`.

    // MARK: every reset acts on the whole selection in ONE undo step

    @MainActor
    func testEveryResetActsOnTheWholeSelectionAndUndoesInOneStep() throws {
        for (name, reset) in resetsUnderTest() {
            let (model, ids) = try modelWithFolder(count: 3)
            model.selection = Set(ids)
            seedEverything(model, ids)
            let before = ids.map { model.frame($0)!.sidecar }

            reset(model)

            // The reported defect: two frames selected, one frame changed.
            let changed = ids.filter { model.frame($0)!.sidecar != before[ids.firstIndex(of: $0)!] }
            XCTAssertEqual(changed.count, ids.count, "\(name) must reach every selected frame, not one")

            // One Command Z, not three. A selection-wide action that registered three
            // groups would leave two frames reset after a single undo.
            model.undoManager.undo()
            for (i, id) in ids.enumerated() {
                XCTAssertEqual(model.frame(id)!.sidecar, before[i],
                               "one undo restores the whole selection after \(name)")
            }
        }
    }

    @MainActor
    func testTheContextMenuResetsKeepAMultiSelectionRatherThanCollapsingItToTheClickedFrame() throws {
        // Finder's rule, and the half that matters here: a right click INSIDE a selection
        // acts on the selection. A reset that collapsed it first would be the reported bug
        // arriving through the menu instead of the inspector.
        let (model, ids) = try modelWithFolder(count: 3)
        model.selection = [ids[0], ids[1]]
        seedEverything(model, ids)

        model.focusForContextMenu(on: ids[1])
        XCTAssertEqual(model.selection, [ids[0], ids[1]], "a click inside the selection keeps it")
        model.resetDevelopSelection()
        XCTAssertNil(model.frame(ids[0])!.sidecar.develop)
        XCTAssertNil(model.frame(ids[1])!.sidecar.develop)
        XCTAssertNotNil(model.frame(ids[2])!.sidecar.develop, "and never reaches outside it")
    }

    // MARK: paste carries every develop field, on disk

    @MainActor
    func testPasteAllCarriesEveryDevelopFieldIncludingToneAndAutoBalanceIntoTheSidecarOnDisk() throws {
        let (model, ids) = try modelWithFolder(count: 3)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))

        // Source and targets disagree on EVERY develop field, so a field that fails to
        // travel shows up as the target keeping its own value rather than as a no-op.
        let source = DevelopSettings(stock: "kodak-gold-200",
                                     tone: .none, autoBalance: false,
                                     base: BaseSettings(mode: .anchor, anchor: 4000,
                                                        ratios: BaseRatios(rg: 0.47, bg: 0.75)))
        let target = DevelopSettings(stock: "kodak-ultramax-400",
                                     tone: .flat, autoBalance: true,
                                     base: BaseSettings(mode: .anchor))
        group(model) { model.apply({ SidecarEdits.setDevelop($0, source) }, to: ids[0], actionName: "seed") }
        for id in ids.dropFirst() {
            group(model) { model.apply({ SidecarEdits.setDevelop($0, target) }, to: id, actionName: "seed") }
        }

        model.copySettings(FrameSettingsSection.all, from: ids[0], to: pasteboard)
        model.selection = Set(ids.dropFirst())
        model.pasteSettings(from: pasteboard)

        for id in ids.dropFirst() {
            let d = try XCTUnwrap(model.frame(id)!.sidecar.develop)
            XCTAssertEqual(d.stock, source.stock, "stock travels")
            XCTAssertEqual(d.tone, source.tone, "tone travels")
            XCTAssertEqual(d.autoBalance, source.autoBalance, "the film edge toggle travels")
            XCTAssertEqual(d.base.ratios, source.base.ratios, "the measured base travels")

            // The sidecar ON DISK, not just the model. A field the model carries and the
            // XMP writer drops looks correct until the next launch, and the sidecar has
            // form here: `AutoTone` once ate `Tone` outright.
            model.flushPendingSave(id)
            let url = model.frame(id)!.url
            let reread = try XCTUnwrap(try SidecarStore().load(for: url))
            let written = try XCTUnwrap(reread.sidecar.develop)
            XCTAssertEqual(written.stock, source.stock, "stock survives the round trip")
            XCTAssertEqual(written.tone, source.tone, "tone survives the round trip")
            XCTAssertEqual(written.autoBalance, source.autoBalance,
                           "the film edge toggle survives the round trip")
        }
    }

    @MainActor
    func testPastePositiveAloneCarriesAutoBalance() throws {
        let (model, ids) = try modelWithFolder(count: 2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))
        group(model) {
            model.apply({ SidecarEdits.setDevelop($0, DevelopSettings(
                stock: "kodak-gold-200", tone: .none, autoBalance: false,
                base: BaseSettings(mode: .anchor))) }, to: ids[0], actionName: "seed")
        }
        group(model) {
            model.apply({ SidecarEdits.setDevelop($0, DevelopSettings(
                stock: "kodak-gold-200", tone: .flat, autoBalance: true,
                base: BaseSettings(mode: .anchor))) }, to: ids[1], actionName: "seed")
        }
        model.copySettings([.positive], from: ids[0], to: pasteboard)
        model.selection = [ids[1]]
        model.pasteSettings(from: pasteboard)
        XCTAssertEqual(model.frame(ids[1])!.sidecar.develop?.autoBalance, false)
        XCTAssertEqual(model.frame(ids[1])!.sidecar.develop?.tone, ToneMode.none)
    }

    // MARK: Copy All from a frame that is not positive

    /// Copy All off a frame seeded with only an enhance and a crop, Paste onto a developed
    /// one. The seeding edit commits the defaults, so the source carries a positive, the
    /// target's Positive block is overwritten, and the payload says it is a full paste.
    @MainActor
    func testCopyAllFromASeededFrameOverwritesTheTargetsPositiveAndSaysSo() throws {
        let (model, ids) = try modelWithFolder(count: 2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))

        // ids[0] is the source and is NEVER developed. It gets an enhance and a crop, so
        // the paste has real work to do and "nothing happened" cannot be mistaken for a
        // pass.
        group(model) {
            model.apply({ s in
                var out = SidecarEdits.setEnhance(s, EnhanceSettings(contrast: 0.42))
                out = SidecarEdits.setGeometry(out, GeometrySettings(rotate: 90, flip: false,
                                                                         straightenDegrees: 0.75,
                                                                         crop: CropRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)))
                return out
            }, to: ids[0], actionName: "seed")
        }
        // That seeding edit went through the funnel, so the source carries the committed
        // defaults and is no longer an "undeveloped source".
        XCTAssertNotNil(model.frame(ids[0])!.sidecar.develop,
                        "seeding an enhance and a crop commits the defaults with them")

        let targetDevelop = DevelopSettings(stock: "kodak-ultramax-400",
                                            tone: .flat, autoBalance: true,
                                            base: BaseSettings(mode: .anchor, anchor: 3900,
                                                               ratios: BaseRatios(rg: 0.51, bg: 0.69)))
        group(model) { model.apply({ SidecarEdits.setDevelop($0, targetDevelop) }, to: ids[1], actionName: "seed") }

        model.copySettings(FrameSettingsSection.all, from: ids[0], to: pasteboard)
        model.selection = [ids[1]]
        model.pasteSettings(from: pasteboard)

        // 1. the target's Positive block IS overwritten, by the source's own committed
        //    defaults. Copy Positive copies what the user can see on the source, and what
        //    they can see is a positive.
        let after = try XCTUnwrap(model.frame(ids[1])!.sidecar.develop)
        XCTAssertEqual(after.stock, ProfileLibrary.genericStockName)
        XCTAssertEqual(after.tone, ToneMode.none)
        XCTAssertNotEqual(after.stock, targetDevelop.stock, "the copied block won, as a full paste")
        XCTAssertNil(after.base.ratios, "the defaults carry no measured pair")

        // 2. and the two other sections traveled as they always did.
        XCTAssertEqual(model.frame(ids[1])!.sidecar.enhance?.contrast, 0.42)
        XCTAssertEqual(model.frame(ids[1])!.sidecar.geometry?.rotate, 90)

        // 3. so this is a FULL paste and the payload says so, with no note.
        let payload = try XCTUnwrap(FrameSettingsPasteboard.read(from: pasteboard))
        XCTAssertEqual(payload.sourceWasPositive, true)
        XCTAssertTrue(payload.sections.contains(.positive))
        XCTAssertEqual(payload.pasteMenuTitle, "Paste Settings")
        XCTAssertNil(model.pasteNote, "nothing was left behind, so there is nothing to apologise for")
    }

    /// The partial-paste NOTE.
    ///
    /// The app's own Copy Positive cannot produce a payload missing its positive section,
    /// because there is always an effective develop to copy, so the reachable route is a
    /// payload written by an OLDER build off a frame that had no develop layer. That is
    /// asserted here at the payload level rather than through `copySettings`, because going
    /// through Copy produces a different payload and the test would be asserting nothing.
    @MainActor
    func testAPayloadThatLostItsPositiveSectionStillSaysWhatItLeftBehind() throws {
        let (model, ids) = try modelWithFolder(count: 2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))

        let targetDevelop = DevelopSettings(stock: "kodak-ultramax-400",
                                            tone: .flat, autoBalance: true,
                                            base: BaseSettings(mode: .anchor, anchor: 3900,
                                                               ratios: BaseRatios(rg: 0.51, bg: 0.69)))
        group(model) { model.apply({ SidecarEdits.setDevelop($0, targetDevelop) }, to: ids[1], actionName: "seed") }

        // A payload exactly as an older build wrote it: Copy All off a frame with no develop
        // layer, so the positive section is absent and `sourceWasPositive` says why.
        var payload = FrameSettingsPayload(sections: [.enhance, .crop])
        payload.sourceWasPositive = false
        payload.enhance = FrameSettingsPayload.Enhance(sliders: EnhanceSettings(contrast: 0.42), look: nil)
        payload.crop = FrameSettingsPayload.Geometry(GeometrySettings(rotate: 90, flip: false,
                                                                      straightenDegrees: 0.75,
                                                                      crop: CropRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)))
        FrameSettingsPasteboard.write(payload, to: pasteboard)

        model.selection = [ids[1]]
        model.pasteSettings(from: pasteboard)

        // The target's whole develop block is untouched, the film edge toggle included.
        let after = try XCTUnwrap(model.frame(ids[1])!.sidecar.develop)
        XCTAssertEqual(after.stock, targetDevelop.stock)
        XCTAssertEqual(after.autoBalance, targetDevelop.autoBalance)
        XCTAssertEqual(after.base.ratios, targetDevelop.base.ratios)

        // The two sections that could travel did.
        XCTAssertEqual(model.frame(ids[1])!.sidecar.enhance?.contrast, 0.42)
        XCTAssertEqual(model.frame(ids[1])!.sidecar.geometry?.rotate, 90)

        // And both surfaces say what was left behind.
        XCTAssertEqual(payload.pasteMenuTitle, "Paste Settings (Enhance and Crop)")
        XCTAssertEqual(FrameSettingsPasteboard.pasteMenuTitle(in: pasteboard),
                       "Paste Settings (Enhance and Crop)")
        XCTAssertEqual(model.pasteNote, FrameSettingsPayload.partialPasteNoteText)
    }

    /// This is why the note reads `sourceWasPositive` and not `sections`.
    @MainActor
    func testADeliberateEnhanceOnlyCopyIsNotReportedAsAFailedPaste() throws {
        let (model, ids) = try modelWithFolder(count: 2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))
        seedEverything(model, [ids[0]])

        model.copySettings([.enhance], from: ids[0], to: pasteboard)
        model.selection = [ids[1]]
        model.pasteSettings(from: pasteboard)

        let payload = try XCTUnwrap(FrameSettingsPasteboard.read(from: pasteboard))
        XCTAssertEqual(payload.sourceWasPositive, true)
        XCTAssertNil(payload.partialPasteNote, "the user asked for one section and got it")
        XCTAssertNil(model.pasteNote)
    }

    /// A payload from a build that did not record the field decodes, pastes, and produces
    /// no note. A guess there would be wrong half the time.
    func testAPayloadFromAnOlderBuildDecodesAndClaimsNothing() throws {
        let json = "{\"app\":\"co.wonders.filmpositive.settings\",\"version\":1,\"sections\":[\"enhance\",\"crop\"],\"crop\":{\"rotate\":0,\"flip\":false,\"straightenDegrees\":0}}"
        let payload = try JSONDecoder().decode(FrameSettingsPayload.self, from: Data(json.utf8))
        XCTAssertTrue(payload.isUsable)
        XCTAssertNil(payload.sourceWasPositive)
        XCTAssertNil(payload.partialPasteNote, "no field, no claim")
        XCTAssertEqual(payload.pasteMenuTitle, "Paste Settings (Enhance and Crop)",
                       "the title is about the payload, which genuinely has no positive")
    }

    // MARK: helpers

    @MainActor
    private func resetsUnderTest() -> [(String, (AppModel) -> Void)] {
        [("Reset Develop", { $0.resetDevelopSelection() }),
         ("Reset Enhance", { $0.resetEnhanceSelection() }),
         ("Reset Crop", { $0.resetCropSelection() })]
    }

    /// Every layer present on every frame, so any reset has something to remove on all of
    /// them and "one frame changed" is distinguishable from "all of them changed".
    @MainActor
    private func seedEverything(_ model: AppModel, _ ids: [Frame.ID]) {
        for id in ids {
            group(model) {
                model.apply({ s in
                    var out = SidecarEdits.setDevelop(s, DevelopSettings(
                        stock: "kodak-gold-200", tone: .flat, autoBalance: true,
                        base: BaseSettings(mode: .anchor)))
                    out = SidecarEdits.setEnhance(out, EnhanceSettings(contrast: 0.3))
                    out = SidecarEdits.setGeometry(out, GeometrySettings(
                        rotate: 90, flip: true, straightenDegrees: 1.5,
                        crop: CropRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)))
                    return out
                }, to: id, actionName: "seed")
            }
        }
    }

    @MainActor
    private func modelWithFolder(count: Int = 3) throws -> (AppModel, [Frame.ID]) {
        let dir = scratch.appendingPathComponent("roll-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0x42, count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
        }
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        // A test has no run loop event, so automatic grouping would swallow every explicit
        // group and one undo would unwind the whole test.
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        let ids = (model.selectedFolder?.frames ?? []).map(\.id)
        XCTAssertEqual(ids.count, count)
        return (model, ids)
    }

    @MainActor
    private func group(_ model: AppModel, _ body: () -> Void) {
        model.undoManager.beginUndoGrouping()
        body()
        model.undoManager.endUndoGrouping()
    }
}

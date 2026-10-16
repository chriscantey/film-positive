import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The frame context menu's actions: Reset Crop, Duplicate, and copy and paste of settings.
///
/// Everything here runs over a real temporary folder, the way `RenderCoordinatorTests`
/// does, because two of the three features are about files on disk and no reading of the
/// code can prove what lands there.
final class FrameActionsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-frame-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Preferences.store = InMemoryPreferences()
    }

    override func tearDownWithError() throws {
        Preferences.store = InMemoryPreferences()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: helpers

    @discardableResult
    private func makeFolder(_ name: String, files: [String]) throws -> URL {
        let dir = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, f) in files.enumerated() {
            // Distinct bytes per file so a duplicate's fingerprint can be checked against
            // the frame it came from rather than against every file in the folder.
            try Data(repeating: UInt8(0x40 + i), count: 64).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    /// The app leaves `groupsByEvent` on, which closes one group per run loop event. A test
    /// has no event loop, so it is turned off here and the explicit groups the model opens
    /// are the top level ones, which is the shape the app produces. Same reasoning as
    /// `UndoScopeTests`.
    @MainActor
    private func makeModel(_ dir: URL) throws -> AppModel {
        let model = AppModel(service: FailingRenderService(message: "no engine in this test"))
        model.undoManager.groupsByEvent = false
        XCTAssertNotNil(model.addFolder(dir))
        return model
    }

    private func develop(_ stock: String = "kodak-gold-200") -> DevelopSettings {
        DevelopSettings(stock: stock, autoTone: false,
                        base: BaseSettings(mode: .anchor, anchor: 4000, ratios: BaseRatios(rg: 0.4764, bg: 0.7156)))
    }

    private let crop = GeometrySettings(rotate: 90, flip: true, straightenDegrees: 1.25,
                                        crop: CropRect(x: 0.1, y: 0.05, w: 0.8, h: 0.9))

    // MARK: Reset Frame

    /// The Frame section's header Reset. It clears rotate, mirror, straighten and crop in
    /// one undo step over the whole selection, and it leaves every other layer alone.
    @MainActor
    func testResetFrameClearsRotateFlipAndCropInOneUndoStep() throws {
        let dir = try makeFolder("reset-frame", files: ["IMG_0001.CR2", "IMG_0002.CR2"])
        let model = try makeModel(dir)
        let ids = model.framesInView.map(\.id)
        model.selection = Set(ids)
        model.applyToSelection({ s in
            SidecarEdits.setEnhance(SidecarEdits.setGeometry(SidecarEdits.setDevelop(s, self.develop()), self.crop),
                                    EnhanceSettings(contrast: 0.4))
        }, actionName: "seed")
        XCTAssertEqual(model.frame(ids[0])?.sidecar.geometry?.rotate, 90)
        XCTAssertEqual(model.frame(ids[0])?.sidecar.geometry?.flip, true)
        XCTAssertNotNil(model.frame(ids[0])?.sidecar.geometry?.crop)
        XCTAssertTrue(model.hasFrameGeometry, "the header's Reset is live while geometry exists")

        model.resetFrameSelection()

        for id in ids {
            let g = model.frame(id)?.sidecar.geometry ?? GeometrySettings()
            XCTAssertEqual(g.rotate, 0, "rotate survived")
            XCTAssertFalse(g.flip, "mirror survived")
            XCTAssertNil(g.crop, "the crop survived")
            XCTAssertEqual(g.straightenDegrees, 0, "the straighten angle survived")
            XCTAssertTrue(g.isIdentity)
            XCTAssertEqual(model.frame(id)?.sidecar.develop, develop(), "the positive layer moved")
            XCTAssertEqual(model.frame(id)?.sidecar.enhance, EnhanceSettings(contrast: 0.4), "the enhance layer moved")
        }
        XCTAssertFalse(model.hasFrameGeometry, "and the button goes quiet once there is nothing to clear")

        // One undo step for the whole selection, like every other bulk reset.
        model.undoManager.undo()
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.geometry, crop, "undo did not restore \(id)")
        }
    }

    // MARK: Reset Crop

    @MainActor
    func testResetCropClearsTheWholeGeometryLayerAndUndoBringsItBack() throws {
        let dir = try makeFolder("reset-crop", files: ["IMG_0001.CR2"])
        let model = try makeModel(dir)
        let id = try XCTUnwrap(model.framesInView.first?.id)
        model.selection = [id]

        model.applyToSelection({ SidecarEdits.setGeometry($0, self.crop) }, actionName: "Crop")
        XCTAssertEqual(model.frame(id)?.sidecar.geometry, crop)

        model.resetCropSelection()
        XCTAssertNil(model.frame(id)?.sidecar.geometry, "an identity geometry is stored as no geometry at all")
        XCTAssertEqual(model.frame(id)?.sidecar.geometry ?? GeometrySettings(), GeometrySettings())

        model.undoManager.undo()
        XCTAssertEqual(model.frame(id)?.sidecar.geometry, crop, "undo did not restore the crop")
    }

    /// The whole selection, one undo step, exactly like Reset Enhance. Nothing else on the
    /// frames moves: a reset of the geometry layer must not touch the positive.
    @MainActor
    func testResetCropCoversTheSelectionInOneUndoStepAndLeavesTheOtherLayersAlone() throws {
        let dir = try makeFolder("reset-crop-bulk", files: ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        let model = try makeModel(dir)
        let ids = model.framesInView.map(\.id)
        model.selection = Set(ids)
        model.applyToSelection({ s in
            SidecarEdits.setEnhance(SidecarEdits.setGeometry(SidecarEdits.setDevelop(s, self.develop()), self.crop),
                                    EnhanceSettings(contrast: 0.4))
        }, actionName: "seed")

        // A right click on a frame that is already part of the selection acts on all of it.
        model.focusForContextMenu(on: ids[1])
        model.resetCropSelection()

        for id in ids {
            XCTAssertNil(model.frame(id)?.sidecar.geometry, "\(String(describing: model.frame(id)?.name)) kept its crop")
            XCTAssertEqual(model.frame(id)?.sidecar.develop, develop(), "the positive layer moved")
            XCTAssertEqual(model.frame(id)?.sidecar.enhance, EnhanceSettings(contrast: 0.4), "the enhance layer moved")
        }

        model.undoManager.undo()
        for id in ids {
            XCTAssertEqual(model.frame(id)?.sidecar.geometry, crop, "one undo must restore every frame")
        }
    }

    // MARK: Duplicate, the naming rule

    func testTheCounterTakesTheFirstFreeNumberFromTwoUpward() {
        XCTAssertEqual(DuplicateName.next(for: "IMG_0001", extension: "CR2", among: ["IMG_0001.CR2"]),
                       "IMG_0001-2.CR2")
        XCTAssertEqual(DuplicateName.next(for: "IMG_0001", extension: "CR2",
                                          among: ["IMG_0001.CR2", "IMG_0001-2.CR2"]),
                       "IMG_0001-3.CR2")
    }

    /// The gap case: a number in use is never handed out again, so a folder holding -2 and
    /// -4 gets a -3 rather than a -5.
    func testAGapIsFilledRatherThanTheHighestNumberExtended() {
        let folder = ["IMG_0001.CR2", "IMG_0001-2.CR2", "IMG_0001-4.CR2"]
        XCTAssertEqual(DuplicateName.next(for: "IMG_0001", extension: "CR2", among: folder), "IMG_0001-3.CR2")
    }

    /// The counter runs on the base name, so a duplicate of a duplicate continues the
    /// series instead of nesting suffixes.
    func testDuplicatingADuplicateContinuesTheSeries() {
        let folder = ["IMG_0001.CR2", "IMG_0001-2.CR2"]
        XCTAssertEqual(DuplicateName.next(for: "IMG_0001-2", extension: "CR2", among: folder), "IMG_0001-3.CR2")
    }

    /// The rule that decides whether a trailing `-N` is ours: only when the un-suffixed
    /// sibling is in the folder. Both directions, because the whole point is that the same
    /// file name gets a different answer depending on what sits beside it.
    func testATrailingNumberIsOnlyOursWhenTheUnsuffixedSiblingExists() {
        XCTAssertEqual(DuplicateName.next(for: "roll-3", extension: "CR2", among: ["roll-3.CR2"]),
                       "roll-3-2.CR2", "with no roll.CR2 beside it, -3 is part of the name")
        XCTAssertEqual(DuplicateName.next(for: "roll-3", extension: "CR2", among: ["roll.CR2", "roll-3.CR2"]),
                       "roll-2.CR2", "with roll.CR2 beside it, -3 is a duplicate counter and 2 is free")
    }

    /// Occupancy is judged on the stem, whatever it is attached to, so a name whose raw is
    /// gone but whose sidecar is still there is not handed out.
    func testAnOccupiedStemBlocksTheNumberWhateverFileHoldsIt() {
        XCTAssertEqual(DuplicateName.next(for: "IMG_0001", extension: "CR2",
                                          among: ["IMG_0001.CR2", "img_0001-2.xmp"]),
                       "IMG_0001-3.CR2")
    }

    func testTheExtensionIsCarriedThroughVerbatim() {
        XCTAssertEqual(DuplicateName.next(for: "a", extension: "cr3", among: ["a.cr3"]), "a-2.cr3")
        XCTAssertEqual(DuplicateName.next(for: "a", extension: "NEF", among: ["a.NEF"]), "a-2.NEF")
    }

    // MARK: Duplicate, against the disk

    @MainActor
    func testDuplicateWritesBothFilesAndCarriesEverySettingOver() throws {
        let dir = try makeFolder("dup", files: ["IMG_0001.CR2", "IMG_0002.CR2"])
        let model = try makeModel(dir)
        let original = try XCTUnwrap(model.framesInView.first?.id)
        model.selection = [original]
        model.applyToSelection({ s in
            SidecarEdits.setEnhance(SidecarEdits.setGeometry(SidecarEdits.setDevelop(s, self.develop()), self.crop),
                                    EnhanceSettings(contrast: 0.4, saturation: -0.2))
        }, actionName: "seed")

        model.duplicateSelection()

        // Frames carry the directory as `FileManager` hands it back, which under a
        // temporary directory is the resolved /private/var form rather than the /var one
        // this test created. Same file, different URL, so the copy is looked up by name.
        let copy = try XCTUnwrap(model.framesInView.first { $0.name == "IMG_0001-2.CR2" })
        let copyURL = copy.url
        let copyXMP = SidecarStore.sidecarURL(for: copyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path), "the raw was not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyXMP.path), "the sidecar was not written")
        XCTAssertEqual(try Data(contentsOf: copyURL), try Data(contentsOf: dir.appendingPathComponent("IMG_0001.CR2")),
                       "the copy does not hold the original's bytes")

        // Every edited section carries over untouched. `source` is the one field that MUST
        // differ: a sidecar describes the image it sits beside, and this one sits beside
        // the copy.
        let before = try XCTUnwrap(model.frame(original)?.sidecar)
        let after = try XCTUnwrap(model.frame(copyURL)?.sidecar)
        XCTAssertEqual(after.develop, before.develop)
        XCTAssertEqual(after.enhance, before.enhance)
        XCTAssertEqual(after.geometry, before.geometry)
        XCTAssertEqual(after.look, before.look)
        XCTAssertEqual(after.capture, before.capture)
        XCTAssertEqual(after.samplePoint, before.samplePoint)
        var normalized = after
        normalized.source = before.source
        XCTAssertEqual(normalized, before, "something other than the source block changed")
        XCTAssertEqual(after.source.name, "IMG_0001-2.CR2")

        // Read back off disk, because the in-memory copy proves nothing about the file.
        let loaded = try XCTUnwrap(SidecarStore().load(for: copyURL))
        XCTAssertEqual(loaded.sidecar.develop, before.develop)
        XCTAssertEqual(loaded.sidecar.enhance, before.enhance)
        XCTAssertEqual(loaded.status, .ok, "the copy's sidecar does not match the copy")
    }

    @MainActor
    func testTheDuplicateLandsRightAfterItsOriginalAndBecomesTheSelection() throws {
        let dir = try makeFolder("dup-order", files: ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        let model = try makeModel(dir)
        let second = try XCTUnwrap(model.framesInView.dropFirst().first?.id)
        model.selection = [second]

        model.duplicateSelection()

        XCTAssertEqual(model.framesInView.map(\.name),
                       ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0002-2.CR2", "IMG_0003.CR2"])
        let copy = try XCTUnwrap(model.framesInView.first { $0.name == "IMG_0002-2.CR2" })
        XCTAssertEqual(model.selection, [copy.id], "the copy is what you are now working on")
    }

    /// Duplicating the ORIGINAL again takes the next free number, and duplicating the
    /// DUPLICATE continues the same series rather than starting a nested one.
    @MainActor
    func testRepeatedDuplicatesWalkOneSeries() throws {
        let dir = try makeFolder("dup-series", files: ["IMG_0001.CR2"])
        let model = try makeModel(dir)
        let original = try XCTUnwrap(model.framesInView.first?.id)

        model.selection = [original]
        model.duplicateSelection()                      // IMG_0001-2
        model.selection = [original]
        model.duplicateSelection()                      // IMG_0001-3, from the original again
        let third = try XCTUnwrap(model.selection.first)
        model.selection = [third]
        model.duplicateSelection()                      // IMG_0001-4, from a duplicate

        XCTAssertEqual(Set(model.framesInView.map(\.name)),
                       ["IMG_0001.CR2", "IMG_0001-2.CR2", "IMG_0001-3.CR2", "IMG_0001-4.CR2"])
    }

    @MainActor
    func testDuplicateCoversTheWholeSelection() throws {
        let dir = try makeFolder("dup-bulk", files: ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        let model = try makeModel(dir)
        let ids = model.framesInView.map(\.id)
        model.selection = [ids[0], ids[2]]

        model.duplicateSelection()

        XCTAssertEqual(model.framesInView.map(\.name),
                       ["IMG_0001.CR2", "IMG_0001-2.CR2", "IMG_0002.CR2", "IMG_0003.CR2", "IMG_0003-2.CR2"])
        XCTAssertEqual(model.selection.count, 2)
        XCTAssertNil(model.lastError)
    }

    // MARK: Copy and paste settings

    private func testPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("fp-frame-actions-\(UUID().uuidString)"))
    }

    /// Three frames: A is the source, B and C are pasted onto. Only the copied section may
    /// move on B and C.
    @MainActor
    private func threeSeededFrames(_ name: String) throws -> (AppModel, [Frame.ID]) {
        let dir = try makeFolder(name, files: ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.CR2"])
        let model = try makeModel(dir)
        let ids = model.framesInView.map(\.id)
        model.selection = Set(ids)
        model.applyToSelection({ s in SidecarEdits.setDevelop(s, self.develop("kodak-ultramax-400")) },
                               actionName: "seed")
        // A alone gets the state that will be copied off it.
        model.selection = [ids[0]]
        model.applyToSelection({ s in
            SidecarEdits.setEnhance(SidecarEdits.setGeometry(SidecarEdits.setDevelop(s, self.develop("kodak-gold-200")),
                                                             self.crop),
                                    EnhanceSettings(contrast: 0.4, saturation: -0.2))
        }, actionName: "seed A")
        return (model, ids)
    }

    @MainActor
    func testCopyEnhanceMovesOnlyTheEnhanceLayer() throws {
        let (model, ids) = try threeSeededFrames("paste-enhance")
        let board = testPasteboard()

        model.copySettings([.enhance], from: ids[0], to: board)
        model.selection = [ids[1], ids[2]]
        model.pasteSettings(from: board)

        let source = try XCTUnwrap(model.frame(ids[0])?.sidecar)
        for id in [ids[1], ids[2]] {
            let s = try XCTUnwrap(model.frame(id)?.sidecar)
            XCTAssertEqual(s.enhance, source.enhance, "the enhance layer did not arrive")
            XCTAssertEqual(s.look, source.look)
            XCTAssertEqual(s.develop?.stock, "kodak-ultramax-400", "the positive layer moved and must not have")
            XCTAssertNil(s.geometry, "the crop moved and must not have")
        }
    }

    @MainActor
    func testCopyAllCarriesAllThreeSections() throws {
        let (model, ids) = try threeSeededFrames("paste-all")
        let board = testPasteboard()

        model.copySettings(FrameSettingsSection.all, from: ids[0], to: board)
        model.selection = [ids[1]]
        model.pasteSettings(from: board)

        let source = try XCTUnwrap(model.frame(ids[0])?.sidecar)
        let target = try XCTUnwrap(model.frame(ids[1])?.sidecar)
        XCTAssertEqual(target.develop, source.develop)
        XCTAssertEqual(target.enhance, source.enhance)
        XCTAssertEqual(target.geometry, source.geometry)
        XCTAssertEqual(target.look, source.look)
    }

    /// Copying the crop off a frame that has none is a real copy: pasting it clears the
    /// target's crop. That is the difference between a section being ABSENT from a payload
    /// and a section carrying an empty value.
    @MainActor
    func testCopyCropFromAnUncroppedFrameClearsTheTargetsCrop() throws {
        let (model, ids) = try threeSeededFrames("paste-empty-crop")
        model.selection = [ids[1]]
        model.applyToSelection({ SidecarEdits.setGeometry($0, self.crop) }, actionName: "seed B")
        let board = testPasteboard()

        model.copySettings([.crop], from: ids[2], to: board)   // C has no crop
        model.selection = [ids[1]]
        model.pasteSettings(from: board)

        XCTAssertNil(model.frame(ids[1])?.sidecar.geometry)
        XCTAssertEqual(model.frame(ids[1])?.sidecar.develop?.stock, "kodak-ultramax-400", "only the crop should have moved")
    }

    /// Copy Positive off a frame nobody has edited carries the EFFECTIVE defaults, because
    /// that is what the user can see on it: the frame renders as a positive whether or not
    /// a develop layer has been written.
    @MainActor
    func testCopyPositiveFromAnUndevelopedFrameCopiesTheDefaults() throws {
        let dir = try makeFolder("paste-undeveloped", files: ["IMG_0001.CR2"])
        let model = try makeModel(dir)
        let id = try XCTUnwrap(model.framesInView.first?.id)
        let board = testPasteboard()

        model.copySettings([.positive], from: id, to: board)
        let payload = try XCTUnwrap(FrameSettingsPasteboard.read(from: board))
        XCTAssertTrue(payload.sections.contains(.positive))
        let frame = try XCTUnwrap(model.frame(id))
        let expected = try XCTUnwrap(model.effectiveDevelop(for: frame))
        XCTAssertEqual(payload.positive?.stock, expected.stock)
        XCTAssertEqual(payload.positive?.tone, expected.tone.rawValue)
        XCTAssertNil(frame.sidecar.develop, "and copying wrote nothing to the source")
    }

    @MainActor
    func testPasteWithNothingCopiedIsANoOp() throws {
        let (model, ids) = try threeSeededFrames("paste-empty")
        let board = testPasteboard()
        let before = ids.map { model.frame($0)?.sidecar }

        model.selection = Set(ids)
        model.pasteSettings(from: board)

        XCTAssertEqual(ids.map { model.frame($0)?.sidecar }, before)
        XCTAssertEqual(model.undoManager.undoActionName, "seed A",
                       "a no-op paste registered an undo step of its own")
    }

    @MainActor
    func testOneUndoRevertsEveryPastedFrame() throws {
        let (model, ids) = try threeSeededFrames("paste-undo")
        let board = testPasteboard()
        model.copySettings(FrameSettingsSection.all, from: ids[0], to: board)
        let before = [ids[1], ids[2]].map { model.frame($0)?.sidecar }

        model.selection = [ids[1], ids[2]]
        model.pasteSettings(from: board)
        XCTAssertNotEqual([ids[1], ids[2]].map { model.frame($0)?.sidecar }, before, "nothing was pasted")

        model.undoManager.undo()
        XCTAssertEqual([ids[1], ids[2]].map { model.frame($0)?.sidecar }, before,
                       "one undo must revert every frame the paste touched")
    }

    /// The wire format itself, so a change to it is a deliberate change rather than an
    /// accident: what goes on the pasteboard is JSON naming the sections and their values,
    /// and it survives a round trip through a real `NSPasteboard`.
    @MainActor
    func testThePayloadIsJsonNamingItsSectionsAndSurvivesThePasteboard() throws {
        let (model, ids) = try threeSeededFrames("paste-shape")
        let board = testPasteboard()
        model.copySettings(FrameSettingsSection.all, from: ids[0], to: board)

        let data = try XCTUnwrap(board.data(forType: FrameSettingsPasteboard.type))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["app"] as? String, "co.wonders.filmpositive.settings")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["sections"] as? [String], ["positive", "enhance", "crop"])
        XCTAssertEqual((json["positive"] as? [String: Any])?["stock"] as? String, "kodak-gold-200")
        XCTAssertEqual((json["crop"] as? [String: Any])?["rotate"] as? Int, 90)
        XCTAssertNotNil((json["enhance"] as? [String: Any])?["sliders"])

        let round = try XCTUnwrap(FrameSettingsPasteboard.read(from: board))
        XCTAssertEqual(round.applied(to: Sidecar(source: SidecarSource(name: "x", size: 0, mtime: Date(), fingerprint: ""))).develop,
                       model.frame(ids[0])?.sidecar.develop)

        // A blob under our UTI that is not ours is refused rather than half decoded.
        let foreign = NSPasteboard(name: NSPasteboard.Name("fp-foreign-\(UUID().uuidString)"))
        foreign.clearContents()
        foreign.setData(Data("{\"app\":\"someone.else\",\"version\":1,\"sections\":[\"crop\"]}".utf8),
                        forType: FrameSettingsPasteboard.type)
        XCTAssertNil(FrameSettingsPasteboard.read(from: foreign))
    }
}

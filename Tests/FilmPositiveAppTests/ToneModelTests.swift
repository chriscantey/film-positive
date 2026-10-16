import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Levels and Curves in the model. Written like a slider over the selection, one undo
/// step per drag, cleared by Reset Enhance, carried by Copy and Paste Settings and by a saved
/// Look, replaced by an applied Look exactly as an unnamed slider is, never written by a wand,
/// read as a shared value or Multiple, and kept through every save and every folder read.
final class ToneModelTests: XCTestCase {
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

    static let lifted = CurvePoints(sanitising: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)])
    static let levels = Levels(inBlack: 0.04, gamma: 1.3, inWhite: 0.96, outBlack: 0.02, outWhite: 0.98)

    @MainActor
    private func enhance(_ m: AppModel, _ id: Frame.ID) -> EnhanceSettings {
        m.frame(id)?.sidecar.enhance ?? .identity
    }

    // MARK: the edits

    func testSetLevelsAndSetCurvesWriteLikeASlider() {
        var s = Sidecar(source: SidecarSource(name: "a.CR2", size: 1, mtime: Date(), fingerprint: "x"))
        s.look = "pop"
        s.colorAuto = WarmthTint(warmth: 0, tint: 0)
        let l = SidecarEdits.setLevels(s, Self.levels)
        XCTAssertEqual(l.enhance?.levels, Self.levels)
        XCTAssertNil(l.look, "a Levels move drops the look name, as a slider does")
        XCTAssertNotNil(l.colorAuto, "and keeps the Color Auto record, which only Warmth and Tint clear")
        let c = SidecarEdits.setCurves(s, Curves(green: Self.lifted))
        XCTAssertEqual(c.enhance?.curves.green, Self.lifted)
        XCTAssertNil(c.look)
        XCTAssertNil(SidecarEdits.setLevels(l, .identity).enhance, "back to identity is no layer at all")
    }

    @MainActor
    func testAHandleWritesEveryFrameAndOneUndoTakesItBack() throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        m.selection = Set(ids)
        m.setLevelsHandle(.gamma, to: 1.5)
        for id in ids { XCTAssertEqual(enhance(m, id).levels.gamma, 1.5) }
        m.undoManager.undo()
        for id in ids { XCTAssertTrue(enhance(m, id).levels.isIdentity, "one undo for the whole selection") }
    }

    @MainActor
    func testADragIsOneUndoStep() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.selection = Set(ids)
        let coalescer = UndoCoalescer(m.undoManager)
        coalescer.begin(AppModel.levelsAction)
        for g in [1.1, 1.2, 1.35, 1.5] { m.setLevelsHandle(.gamma, to: g) }
        coalescer.end()
        coalescer.begin(AppModel.curvesAction)
        for y in [0.55, 0.6, 0.65] {
            m.setCurve(.all, to: CurvePoints(sanitising: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: y), CurvePoint(x: 1, y: 1)]))
        }
        coalescer.end()
        XCTAssertEqual(enhance(m, ids[1]).curves.rgb.points[1].y, 0.65)
        m.undoManager.undo()
        XCTAssertTrue(enhance(m, ids[1]).curves.isIdentity, "the whole curve drag undoes in one press")
        XCTAssertEqual(enhance(m, ids[1]).levels.gamma, 1.5, "and only it")
        m.undoManager.undo()
        XCTAssertTrue(enhance(m, ids[0]).levels.isIdentity, "the whole Levels drag undoes in one press")
    }

    /// A handle written over frames that disagree lands per frame, bounded by each frame's own
    /// other handle, as `setting` promises.
    @MainActor
    func testEachFrameBoundsTheWriteByItsOwnOtherHandle() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.selection = [ids[0]]
        m.setLevelsHandle(.inWhite, to: 0.5)
        m.selection = Set(ids)
        m.setLevelsHandle(.inBlack, to: 0.7)
        XCTAssertEqual(enhance(m, ids[0]).levels.inBlack, 0.49, accuracy: 1e-9, "kept 0.01 under that frame's white")
        XCTAssertEqual(enhance(m, ids[1]).levels.inBlack, 0.7, accuracy: 1e-9)
    }

    @MainActor
    func testACurveWriteLeavesTheOtherChannels() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        m.selection = Set(ids)
        m.setCurve(.red, to: Self.lifted)
        m.setCurve(.blue, to: Self.lifted)
        let c = enhance(m, ids[0]).curves
        XCTAssertEqual(c.red, Self.lifted)
        XCTAssertEqual(c.blue, Self.lifted)
        XCTAssertTrue(c.rgb.isIdentity && c.green.isIdentity)
        m.resetCurvesSelection()
        XCTAssertTrue(enhance(m, ids[0]).curves.isIdentity)
    }

    @MainActor
    func testResetEnhanceClearsBothAndEachGroupResetClearsOnlyItself() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        m.selection = Set(ids)
        m.setLevelsHandle(.gamma, to: 1.4)
        m.setCurve(.all, to: Self.lifted)
        m.resetLevelsSelection()
        XCTAssertTrue(enhance(m, ids[0]).levels.isIdentity)
        XCTAssertFalse(enhance(m, ids[0]).curves.isIdentity, "Reset Levels leaves Curves")
        m.setLevelsHandle(.gamma, to: 1.4)
        m.resetEnhanceSelection()
        XCTAssertNil(m.frame(ids[0])?.sidecar.enhance, "Reset Enhance clears both")
    }

    // MARK: copy, looks, wands

    @MainActor
    func testCopyAndPasteSettingsCarryBoth() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.selection = [ids[0]]
        m.setLevelsHandle(.inBlack, to: 0.1)
        m.setCurve(.green, to: Self.lifted)
        let board = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))
        m.copySettings([.enhance], from: ids[0], to: board)
        m.selection = [ids[1]]
        m.pasteSettings(from: board)
        XCTAssertEqual(enhance(m, ids[1]).levels.inBlack, 0.1)
        XCTAssertEqual(enhance(m, ids[1]).curves.green, Self.lifted)
    }

    /// A saved Look keeps both, and a file of looks round trips them.
    func testASavedLookCarriesBoth() throws {
        var s = EnhanceSettings(contrast: 0.2)
        s.levels = Levels(inBlack: 0.123456, gamma: 1.3)
        s.curves.rgb = Self.lifted
        let kept = LookStore.quantized(s)
        XCTAssertEqual(kept.levels.inBlack, 0.1235, "held at the file's grain")
        XCTAssertEqual(kept.levels.gamma, 1.3)
        XCTAssertEqual(kept.curves.rgb, Self.lifted)
        let look = Look(id: "lc", name: "LC", blurb: "", settings: kept)
        let back = try LookFile.decode(try LookFile.encode([look]))
        XCTAssertEqual(back.first?.settings.levels, kept.levels)
        XCTAssertEqual(back.first?.settings.curves, kept.curves)
    }

    /// Applying a Look treats Levels and Curves as it treats a slider the Look does not name:
    /// the Look replaces the whole layer, so they go to identity unless the Look carries them.
    func testApplyingALookTreatsThemAsAnUnnamedSlider() {
        var s = Sidecar(source: SidecarSource(name: "a.CR2", size: 1, mtime: Date(), fingerprint: "x"))
        var mine = EnhanceSettings(saturation: 0.4)
        mine.levels = Self.levels
        mine.curves.red = Self.lifted
        s = SidecarEdits.setEnhance(s, mine)
        let plain = Look(id: "p", name: "P", blurb: "", settings: EnhanceSettings(contrast: 0.3))
        let applied = SidecarEdits.applyLook(s, plain)
        XCTAssertEqual(applied.enhance?.saturation, 0, "a slider the look does not name goes to 0")
        XCTAssertTrue(applied.enhance?.levels.isIdentity ?? false, "and so do Levels")
        XCTAssertTrue(applied.enhance?.curves.isIdentity ?? false, "and Curves")
        var carrying = EnhanceSettings(contrast: 0.3)
        carrying.levels = Levels(gamma: 0.8)
        let withTone = SidecarEdits.applyLook(s, Look(id: "t", name: "T", blurb: "", settings: carrying))
        XCTAssertEqual(withTone.enhance?.levels.gamma, 0.8, "a look that carries them sets them")
    }

    /// No wand writes them: the Enhance Auto's write, its lit click, and both Color Auto
    /// writes all leave a frame's Levels and Curves exactly as they were.
    func testNoWandWritesThem() {
        var s = Sidecar(source: SidecarSource(name: "a.CR2", size: 1, mtime: Date(), fingerprint: "x"))
        var mine = EnhanceSettings(contrast: 0.5)
        mine.levels = Self.levels
        mine.curves.rgb = Self.lifted
        s = SidecarEdits.setEnhance(s, mine)

        let proposal = AutoEnhance.Proposal(blackPoint: 0.3, brightness: 0.2, highlights: -0.1, saturation: 0.1, vibrance: 0.05)
        let wand = AppModel.autoEnhanceEdit(s, proposal)
        XCTAssertEqual(wand.enhance?.levels, Self.levels)
        XCTAssertEqual(wand.enhance?.curves.rgb, Self.lifted)
        XCTAssertEqual(wand.enhance?.contrast, 0, "the wand still zeroes the sliders it does not own")
        XCTAssertEqual(wand.look, SidecarEdits.autoLookID)

        var smuggled = EnhanceSettings(); smuggled.levels = Levels(gamma: 5); smuggled.curves.blue = Self.lifted
        let direct = SidecarEdits.applyAuto(s, smuggled)
        XCTAssertEqual(direct.enhance?.levels, Self.levels, "values handed to the wand's write are ignored for them")
        XCTAssertTrue(direct.enhance?.curves.blue.isIdentity ?? false)

        let cleared = SidecarEdits.clearAuto(wand)
        XCTAssertEqual(cleared.enhance?.levels, Self.levels, "the lit click keeps them")
        XCTAssertEqual(cleared.enhance?.curves.rgb, Self.lifted)
        XCTAssertEqual(cleared.enhance?.blackPoint, 0, "and takes the wand's sliders away")
        XCTAssertNil(cleared.look)

        let color = SidecarEdits.applyColorAuto(s, WarmthTint(warmth: 0.1, tint: 0.02))
        XCTAssertEqual(color.enhance?.levels, Self.levels)
        XCTAssertEqual(SidecarEdits.clearColorAuto(color).enhance?.curves.rgb, Self.lifted)
    }

    @MainActor
    func testTheLitEnhanceAutoClickKeepsThem() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        m.selection = Set(ids)
        m.setLevelsHandle(.gamma, to: 1.4)
        m.applyAutoEnhance([(ids[0], AutoEnhance.Proposal(blackPoint: 0.3, brightness: 0.2, highlights: -0.1,
                                                         saturation: 0.1, vibrance: 0.05))])
        XCTAssertTrue(m.autoEnhanceLit)
        XCTAssertEqual(enhance(m, ids[0]).levels.gamma, 1.4)
        m.autoEnhanceClicked()
        XCTAssertFalse(m.autoEnhanceLit)
        XCTAssertEqual(enhance(m, ids[0]).levels.gamma, 1.4)
        XCTAssertEqual(enhance(m, ids[0]).blackPoint, 0)
    }

    // MARK: reading a selection

    func testTheSummaryReportsASharedValueOrMultiple() {
        func sidecar(_ e: EnhanceSettings) -> Sidecar {
            var s = Sidecar(source: SidecarSource(name: "a.CR2", size: 1, mtime: Date(), fingerprint: "x"))
            s.enhance = e
            return s
        }
        var a = EnhanceSettings(); a.levels = Levels(inBlack: 0.1, gamma: 1.2); a.curves.red = Self.lifted
        var b = EnhanceSettings(); b.levels = Levels(inBlack: 0.1, gamma: 1.6); b.curves.red = Self.lifted
        let summary = SelectionSummary([sidecar(a), sidecar(b)])
        XCTAssertEqual(summary.levels[.inBlack], .uniform(0.1))
        XCTAssertEqual(summary.levels[.gamma], .multiple)
        XCTAssertEqual(summary.levels[.inWhite], .uniform(1))
        XCTAssertEqual(summary.levelsPosition(.gamma), 1, "a handle the frames disagree on parks at identity")
        XCTAssertEqual(summary.curves[.red], .uniform(Self.lifted))
        XCTAssertEqual(summary.curves[.all], .uniform(.identity))
        XCTAssertTrue(summary.levelsInUse && summary.curvesInUse)

        var c = EnhanceSettings(); c.curves.red = .identity
        let mixed = SelectionSummary([sidecar(a), sidecar(c)])
        XCTAssertEqual(mixed.curves[.red], .multiple)
        XCTAssertEqual(mixed.curve(.red), .identity, "a curve the frames disagree on draws as identity")
        let none = SelectionSummary([sidecar(EnhanceSettings())])
        XCTAssertFalse(none.levelsInUse || none.curvesInUse)
    }

    // MARK: kept on disk

    /// `EnhanceControl.live` rebuilds the layer from the slider list on every folder
    /// read and every save, and carries Levels and Curves beside the sliders. Saved, read back
    /// by a folder scan, and still there.
    @MainActor
    func testBothSurviveASaveAndAFolderRead() throws {
        var e = EnhanceSettings(contrast: 0.2)
        e.levels = Self.levels
        e.curves.rgb = Self.lifted
        // Richness is a slider this app retired, so `live` must zero it.
        XCTAssertTrue(EnhanceControl.retired.contains("richness"), "canary: pick a slider that really is retired")
        e.richness = 0.4
        var s = Sidecar(source: SidecarSource(name: "IMG_0001.CR2", size: 64, mtime: Date(), fingerprint: "x"))
        s.enhance = e
        let live = EnhanceControl.live(e)
        XCTAssertEqual(live.levels, Self.levels, "live keeps Levels")
        XCTAssertEqual(live.curves, e.curves, "and Curves")
        XCTAssertEqual(live.richness, 0, "while still zeroing a retired slider")

        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        let url = try XCTUnwrap(m.frame(ids[0])?.url)
        // Written RAW, around the app's save path, so the rescan below is the only filter.
        try SidecarStore().save(s, for: url)
        let xmp = try String(contentsOf: SidecarStore.sidecarURL(for: url), encoding: .utf8)
        XCTAssertTrue(xmp.contains("FilmPositive:Levels"), "Levels reached the file")
        XCTAssertTrue(xmp.contains("FilmPositive:CurveRGB"), "and the curve")
        let reread = try FolderSession.scan(url.deletingLastPathComponent())
        let back = try XCTUnwrap(reread.first { $0.url.lastPathComponent == url.lastPathComponent })
        XCTAssertEqual(back.sidecar.enhance?.richness, 0,
                       "canary: the folder read really runs live, or the assertions below prove nothing")
        XCTAssertEqual(back.sidecar.enhance?.levels, Self.levels)
        XCTAssertEqual(back.sidecar.enhance?.curves.rgb, Self.lifted)

        // And the app's own save path keeps them.
        try m.writeSidecar(s, for: url)
        let saved = try XCTUnwrap(try SidecarStore().load(for: url)).sidecar.enhance
        XCTAssertEqual(saved?.levels, Self.levels)
        XCTAssertEqual(saved?.curves.rgb, Self.lifted)
        XCTAssertEqual(saved?.richness, 0, "the save path ran live too")
    }
}

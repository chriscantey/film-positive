import XCTest
import AppKit
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The Color group's Auto remembers its write, kept per frame as `Sidecar.colorAuto`, and
/// follows the Enhance Auto's four transitions. Lit while Warmth and Tint still equal the
/// pair it wrote, dim once either moves, a click on a lit one sets both back to 0, and one
/// Undo restores whatever a click changed.
///
/// The neutralizer's own solve is not under test here (`AutoEnhanceTests` owns it), so the
/// dim to lit step writes a pair through `applyColorAuto`, the one path its result takes.
final class ColorAutoStateTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let pair = WarmthTint(warmth: 0.12, tint: -0.04)

    @MainActor
    private func enhance(_ m: AppModel, _ id: Frame.ID) -> EnhanceSettings {
        m.frame(id)?.sidecar.enhance ?? .identity
    }

    @MainActor
    private func slide(_ m: AppModel, _ id: String, to value: Double) throws {
        let control = try XCTUnwrap(EnhanceControl.all.first { $0.id == id }, "no \(id) slider")
        m.applyToSelection({ s in
            SidecarEdits.setEnhance(s, control.setting(s.enhance ?? .identity, to: value))
        }, actionName: control.label)
    }

    /// The four transitions on one frame, with a hand Contrast riding along to prove the Color
    /// Auto only ever touches Warmth and Tint.
    @MainActor
    func testColorAutoLightsDimsClearsAndUndoes() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.selection = [ids[0]]
        try slide(m, "contrast", to: 0.2)
        XCTAssertFalse(m.colorAutoLit, "a frame the Color Auto never ran on reads dim")

        // dim to lit: the write records its pair
        m.applyColorAuto([(ids[0], pair)])
        XCTAssertTrue(m.colorAutoLit)
        XCTAssertEqual(m.frame(ids[0])?.sidecar.colorAuto, pair)
        XCTAssertEqual(enhance(m, ids[0]).warmth, 0.12)
        XCTAssertEqual(enhance(m, ids[0]).tint, -0.04)
        XCTAssertEqual(enhance(m, ids[0]).contrast, 0.2, "the hand Contrast is kept")

        // lit to 0: Warmth and Tint go, the record goes, Contrast stays
        m.colorAutoClicked()
        XCTAssertFalse(m.colorAutoLit)
        XCTAssertEqual(enhance(m, ids[0]).warmth, 0)
        XCTAssertEqual(enhance(m, ids[0]).tint, 0)
        XCTAssertEqual(enhance(m, ids[0]).contrast, 0.2, "a lit click touches Warmth and Tint only")
        XCTAssertNil(m.frame(ids[0])?.sidecar.colorAuto)

        // one undo restores the pair and the lit state
        m.undoManager.undo()
        XCTAssertTrue(m.colorAutoLit, "undo brings the Color Auto back lit")
        XCTAssertEqual(enhance(m, ids[0]).warmth, 0.12)

        // a Warmth edit dims it and clears the record, keeping the values
        try slide(m, "warmth", to: 0.13)
        XCTAssertFalse(m.colorAutoLit, "a Warmth nudge dims it")
        XCTAssertNil(m.frame(ids[0])?.sidecar.colorAuto, "and clears the record")
        XCTAssertEqual(enhance(m, ids[0]).tint, -0.04)
        m.undoManager.undo()
        XCTAssertTrue(m.colorAutoLit, "undoing the nudge lights it again")

        // Tint clears it the same way
        try slide(m, "tint", to: 0)
        XCTAssertNil(m.frame(ids[0])?.sidecar.colorAuto)
        m.undoManager.undo()
        XCTAssertTrue(m.colorAutoLit)
    }

    /// Any other slider leaves the record and the lit state alone.
    @MainActor
    func testOtherSlidersLeaveItLit() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        m.selection = [ids[0]]
        m.applyColorAuto([(ids[0], pair)])
        for id in ["contrast", "saturation", "exposure"] {
            try slide(m, id, to: 0.25)
            XCTAssertTrue(m.colorAutoLit, "\(id) does not dim the Color Auto")
            XCTAssertEqual(m.frame(ids[0])?.sidecar.colorAuto, pair)
        }
    }

    /// Bulk: lit only while EVERY selected frame is lit, and a lit bulk click zeroes them all
    /// in one undo step.
    @MainActor
    func testColorAutoIsLitOnASelectionOnlyWhenEveryFrameIs() throws {
        let (m, ids) = try scratchRollModel(frames: 3, in: scratch)
        m.applyColorAuto([(ids[0], pair), (ids[1], WarmthTint(warmth: -0.2, tint: 0.05))])
        m.selection = [ids[0], ids[1]]
        XCTAssertTrue(m.colorAutoLit, "each frame holds its own pair")
        m.selection = [ids[0], ids[1], ids[2]]
        XCTAssertFalse(m.colorAutoLit, "one frame it never ran on keeps it dim")

        m.selection = [ids[0], ids[1]]
        m.colorAutoClicked()
        XCTAssertEqual(enhance(m, ids[0]).warmth, 0)
        XCTAssertEqual(enhance(m, ids[1]).warmth, 0)
        m.undoManager.undo()
        XCTAssertEqual(enhance(m, ids[0]).warmth, 0.12)
        XCTAssertEqual(enhance(m, ids[1]).warmth, -0.2)
        XCTAssertTrue(m.colorAutoLit)
    }

    /// The Enhance Auto, a Look and Reset each clear the record, because none of them is the
    /// Color Auto's write. The Color Auto in turn dims the Enhance Auto.
    @MainActor
    func testTheOtherWritersClearTheRecord() throws {
        let (m, ids) = try scratchRollModel(frames: 1, in: scratch)
        m.selection = [ids[0]]
        let proposal = AutoEnhance.Proposal(blackPoint: 0.3, brightness: 0.2, highlights: -0.1,
                                            saturation: 0.1, vibrance: 0.05)

        m.applyAutoEnhance([(ids[0], proposal)])
        m.applyColorAuto([(ids[0], pair)])
        XCTAssertFalse(m.autoEnhanceLit, "the Color Auto dims the Enhance Auto")
        XCTAssertTrue(m.colorAutoLit)
        m.applyAutoEnhance([(ids[0], proposal)])
        XCTAssertNil(m.frame(ids[0])?.sidecar.colorAuto, "the Enhance Auto's write clears it")
        XCTAssertFalse(m.colorAutoLit)

        m.applyColorAuto([(ids[0], pair)])
        let look = try XCTUnwrap(ShippedLooks.all.first { !$0.settings.isIdentity })
        m.lookClicked(look)
        XCTAssertNil(m.frame(ids[0])?.sidecar.colorAuto, "a Look clears it")

        m.applyColorAuto([(ids[0], pair)])
        m.applyToSelection(SidecarEdits.resetEnhance, actionName: "Reset Enhance")
        XCTAssertNil(m.frame(ids[0])?.sidecar.colorAuto, "Reset clears it")
    }

    /// Paste All from a lit frame carries the values and not the record: the neutralizer read
    /// the source, not the target, so the Color Auto stays dim there.
    @MainActor
    func testPastedValuesDoNotLightTheTarget() throws {
        let (m, ids) = try scratchRollModel(frames: 2, in: scratch)
        m.applyColorAuto([(ids[0], pair)])
        let board = NSPasteboard(name: NSPasteboard.Name("fp-test-\(UUID().uuidString)"))
        m.copySettings([.enhance], from: ids[0], to: board)
        m.selection = [ids[1]]
        m.pasteSettings(from: board)
        XCTAssertEqual(enhance(m, ids[1]).warmth, 0.12, "the values arrive")
        XCTAssertNil(m.frame(ids[1])?.sidecar.colorAuto)
        XCTAssertFalse(m.colorAutoLit)
    }

    /// Through the real codec and the store: the record survives a save and reopen, and a
    /// sidecar written before the field existed opens dim with its sliders intact.
    @MainActor
    func testTheRecordSurvivesTheFileAndAnOldFileReadsDim() throws {
        var sidecar = Sidecar(source: SidecarSource(name: "IMG_0001.CR2", size: 64,
                                                    mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                                    fingerprint: "sha256:deadbeef"))
        sidecar = SidecarEdits.applyColorAuto(sidecar, WarmthTint(warmth: 0.123456, tint: -0.04))
        let bytes = try sidecar.encoded()
        let back = try Sidecar.decode(bytes, liveSource: sidecar.source, strict: true)
        XCTAssertEqual(back.colorAuto, WarmthTint(warmth: 0.1235, tint: -0.04))
        XCTAssertTrue(try XCTUnwrap(back.colorAuto).isHeld(by: back.enhance), "still lit after a reopen")

        let old = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: #"\s[A-Za-z]+:ColorAuto="[^"]*""#, with: "", options: .regularExpression)
        XCTAssertFalse(old.contains("ColorAuto"), "the key really is gone from the file")
        let legacy = try Sidecar.decode(Data(old.utf8), liveSource: sidecar.source, strict: true)
        XCTAssertNil(legacy.colorAuto, "an old file has no record, so it reads dim")
        XCTAssertEqual(legacy.enhance?.warmth, 0.1235, "and its sliders are as they were")
    }
}

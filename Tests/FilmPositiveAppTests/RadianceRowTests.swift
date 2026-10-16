import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// Radiance's row: first in Light, stored under the package's existing `radiance` key, read and
/// written like every live slider, never set by the Enhance wand, and held at 0 by every
/// built-in Look.
final class RadianceRowTests: XCTestCase {
    static let row = EnhanceControl.all.first { $0.id == "radiance" }!

    static func blank(_ name: String) -> Sidecar {
        Sidecar(source: SidecarSource(name: name, size: 1, mtime: Date(timeIntervalSince1970: 0), fingerprint: "sha256:00"))
    }

    /// The row and its hover help: one plain sentence, then the row's click help.
    func testTheRowSaysWhatItDoes() {
        XCTAssertEqual(EnhanceControl.group(.tone).first?.id, "radiance")
        XCTAssertEqual(Self.row.label, "Radiance")
        XCTAssertEqual(Self.row.symbol, "sparkles")
        let help = "Brightens shadows and holds back highlights, or deepens the picture to the left."
        XCTAssertEqual(Self.row.help, help)
        XCTAssertEqual(EnhanceSliderRow.help(for: Self.row, isMultiple: false), help + " " + SliderHelp.single)
        XCTAssertEqual(EnhanceSliderRow.help(for: Self.row, isMultiple: true), help + " " + SliderHelp.mixed)
        XCTAssertFalse(help.contains("\u{2014}") || help.contains(";") || help.contains("--"), help)
        for word in ["brilliance", "photos", "apple"] { XCTAssertFalse(help.lowercased().contains(word), word) }
        XCTAssertEqual(help.filter { $0 == "." }.count, 1, "one sentence")
    }

    /// The row writes `radiance` and nothing else, with the slider's own sign.
    func testTheRowWritesItsOwnKey() {
        let moved = Self.row.setting(.identity, to: 0.5)
        var expected = EnhanceSettings.identity; expected.radiance = 0.5
        XCTAssertEqual(moved, expected)
        XCTAssertEqual(Self.row.value(in: moved), 0.5)
    }

    /// A sidecar carrying Radiance reads it, renders it, and writes it back: the key is live.
    @MainActor
    func testASidecarCarryingRadianceKeepsIt() throws {
        let raw = try JSONDecoder().decode(EnhanceSettings.self, from: Data(#"{"radiance": 0.5, "contrast": 0.2}"#.utf8))
        XCTAssertEqual(EnhanceControl.live(raw), raw)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-radiance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let image = scratch.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 64).write(to: image)
        let source = try SidecarStore.source(for: image)
        try Sidecar(source: source, enhance: raw).encoded().write(to: SidecarStore.sidecarURL(for: image))

        let frame = try XCTUnwrap(try FolderSession.scan(scratch).first)
        XCTAssertEqual(frame.sidecar.enhance, raw, "read with Radiance")

        let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        try model.writeSidecar(frame.sidecar, for: image)
        let written = try Data(contentsOf: SidecarStore.sidecarURL(for: image))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("Radiance"), "the key is written back")
        XCTAssertEqual(try XCTUnwrap(SidecarStore().load(for: image)).sidecar.enhance, raw)

        // The value reaches the chain.
        let pixels = DecodedFrame(width: 4, height: 2, pixels: (0..<24).map { UInt16($0 * 2500) })
        var without = raw; without.radiance = 0
        XCTAssertNotEqual(try CoreImageEnhance().apply(pixels, settings: raw).pixels,
                          try CoreImageEnhance().apply(pixels, settings: without).pixels)
    }

    /// The Enhance wand does not set Radiance. It writes over a zeroed layer, so a hand
    /// Radiance goes to 0 with every slider it does not own, and its own write never touches it.
    func testTheWandDoesNotSetRadiance() {
        let proposal = AutoEnhance.Proposal(blackPoint: 0.1, brightness: 0.2, highlights: -0.1, saturation: 0.1,
                                            vibrance: 0.1, warmth: 0.05, tint: -0.02, shadows: 0.1, exposure: 0.1)
        var carrying = Self.blank("a.CR2")
        carrying.enhance = Self.row.setting(.identity, to: 0.6)
        XCTAssertEqual(AppModel.autoEnhanceEdit(carrying, proposal).enhance?.radiance, 0)
        XCTAssertEqual(AppModel.autoEnhanceEdit(Self.blank("b.CR2"), proposal).enhance?.radiance, 0)
        XCTAssertEqual(proposal.applied(to: Self.row.setting(.identity, to: 0.6)).radiance, 0.6,
                       "the proposal's own write leaves Radiance where it was")
    }

    /// Every built-in Look holds Radiance at 0, so a built-in Look renders as it did without
    /// the row.
    func testBuiltInLooksHoldRadianceAtZero() {
        for look in ShippedLooks.all { XCTAssertEqual(look.settings.radiance, 0, look.id) }
    }
}

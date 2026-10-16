import XCTest
import FilmSidecar
import FilmPositiveCore
@testable import FilmPositive

/// The app retired one enhance slider, Richness, while the shared sidecar package still
/// carries its key. A file an older build wrote with that key has to read, render and save
/// exactly like the same file without it. Every test here runs once per retired key
/// (`EnhanceControl.retiredSliderKeys`), which is Richness alone: Radiance has its row back and
/// is live, which `RadianceRowTests` covers.
final class RetiredSliderTests: XCTestCase {
    static let trailingKey = "richness"

    /// Enhance settings carrying one retired slider at 0.5 beside an ordinary Contrast, built
    /// through the package's own JSON form.
    static func withRetired(_ key: String) throws -> EnhanceSettings {
        try JSONDecoder().decode(EnhanceSettings.self,
                                 from: Data(#"{"\#(key)": 0.5, "contrast": 0.2}"#.utf8))
    }

    func testTheSliderCountAndTheRetiredKeysAreWhereThePackageHasThem() {
        XCTAssertEqual(EnhanceSettings.sliderKeys.count, EnhanceControl.liveSliderKeys.count + 1,
                       "exactly one retired key")
        XCTAssertTrue(EnhanceSettings.sliderKeys.contains(Self.trailingKey), "the package still carries it")
        XCTAssertEqual(EnhanceControl.retiredSliderKeys, [Self.trailingKey])
        XCTAssertTrue(EnhanceControl.liveSliderKeys.contains("radiance"), "Radiance is live")
        XCTAssertEqual(Array(EnhanceSettings.sliderKeys.suffix(2)), ["vignetteSize", "vignetteFeather"],
                       "the keys appended after it are live, which a cut by position would have retired")
        for key in ["vignetteSize", "vignetteFeather"] {
            XCTAssertTrue(EnhanceControl.liveSliderKeys.contains(key), key)
        }
        for key in EnhanceControl.retiredSliderKeys {
            XCTAssertFalse(EnhanceControl.all.contains { $0.id == key }, "no row for \(key)")
        }
    }

    @MainActor
    func testAnOldSidecarCarryingTheKeyReadsAsIfItWereZero() throws {
        for key in EnhanceControl.retiredSliderKeys { try readsAsZero(key) }
    }

    @MainActor
    func readsAsZero(_ retiredKey: String) throws {
        let raw = try Self.withRetired(retiredKey)
        let index = try XCTUnwrap(EnhanceSettings.sliderKeys.firstIndex(of: retiredKey))
        XCTAssertNotEqual(raw.values[index], 0, "the fixture really carries \(retiredKey)")

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let image = scratch.appendingPathComponent("IMG_0001.CR2")
        try Data(repeating: 0x42, count: 64).write(to: image)
        let source = try SidecarStore.source(for: image)
        let xmp = try Sidecar(source: source, enhance: raw).encoded()
        let attribute = retiredKey.prefix(1).uppercased() + retiredKey.dropFirst()
        XCTAssertTrue(String(decoding: xmp, as: UTF8.self).contains(attribute), "the file on disk carries the key")
        try xmp.write(to: SidecarStore.sidecarURL(for: image))

        // Read: the frame holds Contrast and nothing else.
        let frame = try XCTUnwrap(try FolderSession.scan(scratch).first)
        var expected = EnhanceSettings(); expected.contrast = 0.2
        XCTAssertEqual(frame.sidecar.enhance, expected)

        // Render: what the app hands the chain gives the same pixels as the key at 0, and the
        // chain has no step for the key at all.
        let pixels = DecodedFrame(width: 4, height: 2, pixels: (0..<24).map { UInt16($0 * 2500) })
        XCTAssertEqual(try CoreImageEnhance().apply(pixels, settings: EnhanceControl.live(raw)).pixels,
                       try CoreImageEnhance().apply(pixels, settings: expected).pixels)
        XCTAssertEqual(try CoreImageEnhance().apply(pixels, settings: raw).pixels,
                       try CoreImageEnhance().apply(pixels, settings: expected).pixels)

        // Write: the next save drops the key from the file.
        let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
        var carrying = frame.sidecar; carrying.enhance = raw
        try model.writeSidecar(carrying, for: image)
        let written = try Data(contentsOf: SidecarStore.sidecarURL(for: image))
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains(attribute), "the key is not written back")
        XCTAssertEqual(try XCTUnwrap(SidecarStore().load(for: image)).sidecar.enhance, expected)
    }

    /// A saved look carrying a retired key comes back without it.
    func testALookDropsTheKey() throws {
        var expected = EnhanceSettings(); expected.contrast = 0.2
        for key in EnhanceControl.retiredSliderKeys {
            XCTAssertEqual(LookStore.quantized(try Self.withRetired(key)), expected, key)
        }
    }

    /// No shipped Look carries a retired key, since the app would read it as 0 anyway.
    func testNoShippedLookCarriesARetiredKey() {
        for look in ShippedLooks.all {
            for key in EnhanceControl.retiredSliderKeys {
                let i = EnhanceSettings.sliderKeys.firstIndex(of: key)!
                XCTAssertEqual(look.settings.values[i], 0, "\(look.id) carries \(key)")
            }
        }
    }
}
